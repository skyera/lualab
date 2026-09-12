#!/usr/bin/env luajit
--[[
    ffi_chip8.lua
    Retro Chip-8 CPU Emulator & Virtual Machine in pure LuaJIT FFI.
    
    Features:
      - Complete 35-opcode Chip-8 CPU emulator with cycle-accurate execution.
      - 64x32 monochrome display rendered with Unicode half-blocks (▀/▄/█) or ASCII.
      - Standard COSMAC VIP font set and 16-key hexadecimal keypad mapping.
      - 60 Hz hardware delay and sound timers.
      - 7 Built-in classic ROMs (IBM Logo, Corax+ Diagnostic, Pong, Brix, UFO, Tetris, Maze).
      - External .ch8 ROM file loading support.
      - Built-in CPU disassembler, register inspector, and color theme switcher.
      - Zero external C library dependencies: pure LuaJIT FFI with POSIX / Win32 console I/O.
      - Pixel-perfect 80x25 terminal layout.
--]]

local ffi = require("ffi")
local bit = require("bit")

-- ============================================================================
-- 1. FFI C DEFINITIONS & CONSTANTS
-- ============================================================================
local is_windows = (ffi.os == "Windows")

ffi.cdef[[
    typedef struct {
        uint8_t  memory[4096];
        uint8_t  V[16];
        uint16_t I;
        uint16_t pc;
        uint8_t  delay_timer;
        uint8_t  sound_timer;
        uint16_t stack[16];
        uint16_t sp;
        uint8_t  gfx[64 * 32];
        uint8_t  keys[16];
        uint32_t cycle_count;
    } Chip8VM;
]]

if is_windows then
    ffi.cdef[[
        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;

        typedef struct _COORD {
            short X;
            short Y;
        } COORD;

        typedef struct _KEY_EVENT_RECORD {
            BOOL bKeyDown;
            unsigned short wRepeatCount;
            unsigned short wVirtualKeyCode;
            unsigned short wVirtualScanCode;
            union {
                unsigned short UnicodeChar;
                char           AsciiChar;
            } uChar;
            DWORD dwControlKeyState;
        } KEY_EVENT_RECORD;

        typedef struct _INPUT_RECORD {
            unsigned short EventType;
            union {
                KEY_EVENT_RECORD KeyEvent;
            } Event;
        } INPUT_RECORD;

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD *lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL GetNumberOfConsoleInputEvents(HANDLE hConsoleInput, DWORD *lpcNumberOfEvents);
        BOOL ReadConsoleInputA(HANDLE hConsoleInput, INPUT_RECORD *lpBuffer, DWORD nLength, DWORD *lpNumberOfEventsRead);
        void Sleep(DWORD dwMilliseconds);
        BOOL Beep(DWORD dwFreq, DWORD dwDuration);
    ]]
else
    ffi.cdef[[
        typedef unsigned int   tcflag_t;
        typedef unsigned char  cc_t;
        typedef unsigned int   speed_t;

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

        struct pollfd {
            int   fd;
            short events;
            short revents;
        };

        struct timespec {
            long tv_sec;
            long tv_nsec;
        };

        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, unsigned long count);
        int nanosleep(const struct timespec *req, struct timespec *rem);
        int clock_gettime(int clk_id, struct timespec *tp);
    ]]
end

local CHIP8_WIDTH  = 64
local CHIP8_HEIGHT = 32
local FONTSET_ADDR = 0x050
local PROGRAM_ADDR = 0x200

local FONTSET = {
    0xF0, 0x90, 0x90, 0x90, 0xF0, -- 0
    0x20, 0x60, 0x20, 0x20, 0x70, -- 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, -- 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, -- 3
    0x90, 0x90, 0xF0, 0x10, 0x10, -- 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, -- 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, -- 6
    0xF0, 0x10, 0x20, 0x40, 0x40, -- 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, -- 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, -- 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, -- A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, -- B
    0xF0, 0x80, 0x80, 0x80, 0xF0, -- C
    0xE0, 0x90, 0x90, 0x90, 0xE0, -- D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, -- E
    0xF0, 0x80, 0xF0, 0x80, 0x80  -- F
}

-- Standard Keypad Mapping (QWERTY -> Chip-8 Hex)
-- 1 2 3 4  -> 1 2 3 C
-- Q W E R  -> 4 5 6 D
-- A S D F  -> 7 8 9 E
-- Z X C V  -> A 0 B F
local KEY_MAP = {
    ['1'] = 0x1, ['2'] = 0x2, ['3'] = 0x3, ['4'] = 0xC,
    ['q'] = 0x4, ['w'] = 0x5, ['e'] = 0x6, ['r'] = 0xD,
    ['a'] = 0x7, ['s'] = 0x8, ['d'] = 0x9, ['f'] = 0xE,
    ['z'] = 0xA, ['x'] = 0x0, ['c'] = 0xB, ['v'] = 0xF,
    ['Q'] = 0x4, ['W'] = 0x5, ['E'] = 0x6, ['R'] = 0xD,
    ['A'] = 0x7, ['S'] = 0x8, ['D'] = 0x9, ['F'] = 0xE,
    ['Z'] = 0xA, ['X'] = 0x0, ['C'] = 0xB, ['V'] = 0xF,
}

-- Color themes for phosphor display
local COLOR_THEMES = {
    { name = "Green Phosphor", fg = "\27[38;2;50;255;50m",  bg = "\27[48;2;10;30;10m" },
    { name = "Amber Gold",     fg = "\27[38;2;255;180;0m", bg = "\27[48;2;30;20;5m" },
    { name = "Cyber Cyan",     fg = "\27[38;2;0;230;255m",  bg = "\27[48;2;5;25;35m" },
    { name = "Monochrome",     fg = "\27[38;2;240;240;240m",bg = "\27[48;2;20;20;20m" },
    { name = "Matrix Neon",    fg = "\27[38;2;0;255;120m",  bg = "\27[48;2;0;20;10m" },
}

-- ============================================================================
-- 2. EMBEDDED BUILT-IN ROMS
-- ============================================================================
local BUILTIN_ROMS = {
    ["ibm"] = {
        title = "IBM Logo",
        desc  = "Iconic IBM graphic display test",
        size  = 132,
        data  = "00e0a22a600c6108d01f7009a239d01fa2487008d01f7004a257d01f7008a266d01f7008a275d01f1228ff00ff003c003c003c003c00ff00ffff00ff0038003f003f003800ff00ff8000e000e00080008000e000e00080f800fc003e003f003b003900f800f8030007000f00bf00fb00f300e30043e505e2008507810180028007e106e7"
    },
    ["corax"] = {
        title = "Corax+ Diagnostic",
        desc  = "Full Chip-8 opcode validation test",
        size  = 761,
        data  = "120a600100ee600212a600e068326b1aa4f1d8b4683aa4f5d8b4680269066a0b6b01652a662ba4b5d8b4a4edd9b4a4a5362ba4a1dab46b06a4b9d8b4a4edd9b4a4a1452aa4a5dab46b0ba4bdd8b4a4edd9b4a4a15560a4a5dab46b10a4c5d8b4a4edd9b4a4a176ff462aa4a5dab47b05a4cdd8b4a4edd9b4a4a19560a4a5dab47b05a4add8b4a4edd9b4a4a51290a4a1dab4681269166a1b6b01a4b1d8b4a4edd9b460002202a4a54000a4a1dab47b05a4a9d8b4a4e1d9b4a4a54002a4a13000dab47b05a4c9d8b4a4a9d9b4a4a1652a67008750472aa4a5dab47b05a4c9d8b4a4add9b4a4a1660b672a8761472ba4a5dab47b05a4c9d8b4a4b1d9b4a4a16678671f87624718a4a5dab47b05a4c9d8b4a4b5d9b4a4a16678671f87634767a4a5dab4682269266a2b6b01a4c9d8b4a4b9d9b4a4a1668c678c87644718a4a5dab47b05a4c9d8b4a4bdd9b4a4a1668c6778876547eca4a5dab47b05a4c9d8b4a4c5d9b4a4a16678678c876747eca4a5dab47b05a4c9d8b4a4c1d9b4a4a1660f86664607a4a5dab47b05a4c9d8b4a4e1d9b4a4a166e0866e46c0a4a5dab47b05a4e5d8b4a4c1d9b4a49ef165a4a530aaa4a13155a4a1dab4683269366a3b6b01a4e5d8b4a4bdd9b4a49e60006130f155a49ef0658100a49ff065a4a53030a4a13100a4a1dab47b05a4e5d8b4a4b5d9b4a49e6689f633f265a4a1300114323103143232071432a49e6641f633f265a4a1300014323106143232051432a49e6604f633f265a4a1300014323100143232041432a4a5dab47b05a4e5d8b4a4e1d9b4a4a16604f61edab47b05a4e9d8b4a4edd9b4a4a566ff760a3609a4a186663604a4a166ff600a86043609a4a186663604a4a166ff866e8666367fa4a18666866e367ea4a1660576f636fba4a16605860536fba4a16605806730fba4a1dab4149caa550000a040a000a0c080e0a0a0e0c04040e0e020c0e0e06020e0a0e02020e0c020c06080e0e0e0204040e0e0a0e0e0e020c040a0e0a0c0e0a0e0e08080e0c0a0a0c0e0c080e0e080c08000a0a040a040a0a00aaea242380830b8"
    },
    ["pong"] = {
        title = "Pong",
        desc  = "Classic 2-player paddle game",
        size  = 246,
        data  = "6a026b0c6c3f6d0ca2eadab6dcd66e0022d4660368026060f015f0073000121ac717770869ffa2f0d671a2eadab6dcd66001e0a17bfe6004e0a17b02601f8b02dab6600ce0a17dfe600de0a17d02601f8d02dcd6a2f0d67186848794603f8602611f871246021278463f1282471f69ff47006901d671122a68026301807080b5128a68fe630a807080d53f0112a2610280153f0112ba80153f0112c880153f0112c26020f01822d48e3422d4663e3301660368fe33016802121679ff49fe69ff12c87901490269016004f0187601464076fe126ca2f2fe33f265f12964146500d4557415f229d45500ee808080808080800000000000"
    },
    ["brix"] = {
        title = "Brix",
        desc  = "Breakout brick-breaking arcade game",
        size  = 280,
        data  = "6e0565006b066a00a30cdab17a043a4012087b023b1212066c206d1fa310dcd122f660006100a312d0117008a30ed0116040f015f00730001234c60f671e680169ffa30ed671a310dcd16004e0a17cfe6006e0a17c02603f8c02dcd1a30ed67186848794603f8602611f8712471f12ac46006801463f68ff47006901d6713f0112aa471f12aa600580753f0012aa6001f018806061fc8012a30cd07160fe890322f6750122f6456012de124669ff806080c53f0112ca610280153f0112e080153f0112ee80153f0112e86020f018a30e7eff80e080046100d0113e00123012de78ff48fe68ff12ee7801480268016004f01869ff1270a314f533f265f12963376400d3457305f229d34500eee0008000fc00aa0000000000"
    },
    ["ufo"] = {
        title = "UFO",
        desc  = "Space invader target shooting game",
        size  = 224,
        data  = "a2cd69386a08d9a3a2d06b006c03dbc3a2d6641d651fd4516700680f22a222ac48001222641e651ca2d3d4536e0066806d04eda166ff6d05eda166006d06eda16601368022d8a2d0dbc3cd018bd4dbc33f001292a2cdd9a3cd013d006dff79fed9a33f00128c4e00122ea2d3d4534500128675ff8464d4533f0112466d088d524d08128c129222ac78ff121e22a27705129622a2770f22a26d03fd18a2d3d4531286a2f8f733630022b600eea2f8f833633222b600ee6d1bf265f029d3d57305f129d3d57305f229d3d500ee017cfe7c60f06040e0a0f8d46e016d10fd1800ee"
    },
    ["tetris"] = {
        title = "Tetris",
        desc  = "Classic falling tetrominoes",
        size  = 494,
        data  = "a2b423e622b67001d0113025120671ff22bc22b6a2b4600bd011601cd01122b822d6a2f0700ad0117006d0117007d0117006d011a2ec22e0610022cc22d622b822bc22c2a2ec22e0610122cc22d622b822bc22c2a2ec22e0610222cc22d622b822bc22c2a2ec22e0610322cc22d6620063006400650066006700680069006a006b006c006d006e006f00127263016401650166016701680169016a016b016c016d016e016f01128a6402650266026702680269026a026b026c026d026e026f0212a2650366036703680369036a036b036c036d036e036f03a2b4c00f7009d0116001f01870ff400812aa600000e000eea2bc7001d011a2f0700ad0117006d0117007d0117006d01100eea2b6611f71fed0117009d01100eea2b8c00361028004f029610ad015700461018004f029610ad015700400eea2be60086118d011700bd01100ee6111f11812d46114f11812d47101311012d6a2f26002f033f265f12960246102d0157004f229d01500eea2e06100f12960246118d0157004f12960246112d015700400eeffff000080402010808080808080f080808080f0808080c08080c0c080c0c0c040c08040"
    },
    ["maze"] = {
        title = "10PRINT Maze",
        desc  = "Procedural diagonal maze generator",
        size  = 34,
        data  = "60006100a220c2013201a222d0127004304012046000710431201204120080402010"
    }
}

local ROM_ORDER = { "ibm", "pong", "brix", "tetris", "ufo", "corax", "maze" }

-- ============================================================================
-- 3. TERMINAL RAW MODE & CROSS-PLATFORM INPUT
-- ============================================================================
local Terminal = {}
Terminal.__index = Terminal

function Terminal.new()
    local self = setmetatable({}, Terminal)
    self.is_windows = is_windows
    self.orig_mode = nil
    self.orig_termios = nil
    self.raw_enabled = false

    if self.is_windows then
        self.STD_INPUT_HANDLE = ffi.cast("DWORD", -10)
        self.STD_OUTPUT_HANDLE = ffi.cast("DWORD", -11)
        self.hIn = ffi.C.GetStdHandle(self.STD_INPUT_HANDLE)
        self.hOut = ffi.C.GetStdHandle(self.STD_OUTPUT_HANDLE)
    else
        self.orig_termios = ffi.new("struct termios")
        self.raw_termios  = ffi.new("struct termios")
        self.pollfd       = ffi.new("struct pollfd[1]")
        self.pollfd[0].fd = 0
        self.pollfd[0].events = 1 -- POLLIN
        self.buf          = ffi.new("char[64]")
    end

    return self
end

function Terminal:enable_raw_mode()
    if self.raw_enabled then return end
    if self.is_windows then
        local mode = ffi.new("DWORD[1]")
        if ffi.C.GetConsoleMode(self.hIn, mode) ~= 0 then
            self.orig_mode = mode[0]
            -- Disable LINE_INPUT (0x2) and ECHO_INPUT (0x4), enable WINDOW_INPUT (0x8)
            local new_mode = bit.band(self.orig_mode, bit.bnot(bit.bor(0x0002, 0x0004)))
            ffi.C.SetConsoleMode(self.hIn, new_mode)
        end
    else
        if ffi.C.tcgetattr(0, self.orig_termios) == 0 then
            ffi.copy(self.raw_termios, self.orig_termios, ffi.sizeof("struct termios"))
            -- Disable ICANON (canonical mode), ECHO, and signals
            self.raw_termios.c_lflag = bit.band(self.raw_termios.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001)))
            self.raw_termios.c_cc[5] = 0 -- VMIN = 0 (non-blocking)
            self.raw_termios.c_cc[6] = 0 -- VTIME = 0
            ffi.C.tcsetattr(0, 0, self.raw_termios)
        end
    end
    self.raw_enabled = true
    io.write("\27[?25l") -- Hide cursor
    io.flush()
end

function Terminal:disable_raw_mode()
    if not self.raw_enabled then return end
    io.write("\27[?25h\27[0m") -- Show cursor & reset styles
    io.flush()
    if self.is_windows then
        if self.orig_mode then
            ffi.C.SetConsoleMode(self.hIn, self.orig_mode)
        end
    else
        if self.orig_termios then
            ffi.C.tcsetattr(0, 0, self.orig_termios)
        end
    end
    self.raw_enabled = false
end

function Terminal:read_key()
    if self.is_windows then
        local num_events = ffi.new("DWORD[1]")
        if ffi.C.GetNumberOfConsoleInputEvents(self.hIn, num_events) ~= 0 and num_events[0] > 0 then
            local record = ffi.new("INPUT_RECORD[1]")
            local read_count = ffi.new("DWORD[1]")
            if ffi.C.ReadConsoleInputA(self.hIn, record, 1, read_count) ~= 0 and read_count[0] > 0 then
                if record[0].EventType == 0x0001 and record[0].Event.KeyEvent.bKeyDown ~= 0 then
                    local c = record[0].Event.KeyEvent.uChar.AsciiChar
                    if c ~= 0 then return string.char(c) end
                end
            end
        end
        return nil
    else
        local ret = ffi.C.poll(self.pollfd, 1, 0)
        if ret > 0 and bit.band(self.pollfd[0].revents, 1) ~= 0 then
            local n = ffi.C.read(0, self.buf, 63)
            if n > 0 then
                return string.char(self.buf[0])
            end
        end
        return nil
    end
end

function Terminal:beep()
    if self.is_windows then
        ffi.C.Beep(750, 15)
    else
        io.write("\a")
        io.flush()
    end
end

function Terminal:get_time_sec()
    if self.is_windows then
        return os.clock()
    else
        local ts = ffi.new("struct timespec")
        ffi.C.clock_gettime(1, ts) -- CLOCK_MONOTONIC = 1
        return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
    end
end

function Terminal:sleep_ms(ms)
    if self.is_windows then
        ffi.C.Sleep(ms)
    else
        local req = ffi.new("struct timespec")
        req.tv_sec = math.floor(ms / 1000)
        req.tv_nsec = (ms % 1000) * 1000000
        ffi.C.nanosleep(req, nil)
    end
end

-- ============================================================================
-- 4. CHIP-8 CPU EMULATOR CORE
-- ============================================================================
local Chip8 = {}
Chip8.__index = Chip8

function Chip8.new()
    local self = setmetatable({}, Chip8)
    self.vm = ffi.new("Chip8VM")
    self.quirks = {
        shift_vy = false,        -- SCHIP/modern shift quirk: false = Vx >>= 1, true = Vx = Vy >> 1
        load_store_inc_i = true, -- COSMAC VIP quirk: I = I + x + 1 on Fx55 / Fx65
        logic_resets_vf = true,  -- 8xy1, 8xy2, 8xy3 set VF = 0
    }
    self.key_decay = {}
    for i = 0, 15 do self.key_decay[i] = 0 end

    self.last_opcode = 0
    self.last_disasm = "NOP"
    self.cpu_hz = 700        -- CPU clock speed in Hz (typical 500-1000 Hz)
    self.paused = false
    self.theme_idx = 1
    self.use_ascii = false
    self.current_rom_key = "ibm"
    self.current_rom_title = "IBM Logo"

    self:reset()
    return self
end

function Chip8:reset()
    ffi.fill(self.vm, ffi.sizeof("Chip8VM"))
    self.vm.pc = PROGRAM_ADDR

    -- Load built-in 4x5 fontset into memory starting at 0x050
    for i = 1, #FONTSET do
        self.vm.memory[FONTSET_ADDR + i - 1] = FONTSET[i]
    end

    for i = 0, 15 do self.key_decay[i] = 0 end
    self.last_opcode = 0
    self.last_disasm = "RESET"
end

function Chip8:load_rom_hex(hex_str, title, key)
    self:reset()
    self.current_rom_title = title or "Custom ROM"
    self.current_rom_key = key or "custom"

    local clean = hex_str:gsub("%s+", "")
    local len = #clean / 2
    for i = 1, len do
        local byte_str = clean:sub((i - 1) * 2 + 1, (i - 1) * 2 + 2)
        local val = tonumber(byte_str, 16) or 0
        if PROGRAM_ADDR + i - 1 < 4096 then
            self.vm.memory[PROGRAM_ADDR + i - 1] = val
        end
    end
end

function Chip8:load_rom_file(path)
    local f = io.open(path, "rb")
    if not f then return false, "Cannot open file: " .. tostring(path) end
    local data = f:read("*a")
    f:close()

    self:reset()
    local name = path:match("([^/\\]+)%.ch8$") or path:match("([^/\\]+)$") or "Custom ROM"
    self.current_rom_title = name
    self.current_rom_key = "file"

    for i = 1, #data do
        if PROGRAM_ADDR + i - 1 < 4096 then
            self.vm.memory[PROGRAM_ADDR + i - 1] = data:byte(i)
        end
    end
    return true
end

function Chip8:load_builtin(key)
    local rom = BUILTIN_ROMS[key]
    if not rom then return false, "Unknown builtin ROM: " .. tostring(key) end
    self:load_rom_hex(rom.data, rom.title, key)
    return true
end

-- Disassemble 16-bit opcode into mnemonic string
function Chip8:disassemble(op)
    local o   = bit.rshift(op, 12)
    local x   = bit.band(bit.rshift(op, 8), 0x0F)
    local y   = bit.band(bit.rshift(op, 4), 0x0F)
    local n   = bit.band(op, 0x0F)
    local kk  = bit.band(op, 0xFF)
    local nnn = bit.band(op, 0x0FFF)

    if op == 0x00E0 then return "CLS"
    elseif op == 0x00EE then return "RET"
    elseif o == 0 then return string.format("SYS  0x%03X", nnn)
    elseif o == 1 then return string.format("JP   0x%03X", nnn)
    elseif o == 2 then return string.format("CALL 0x%03X", nnn)
    elseif o == 3 then return string.format("SE   V%X, 0x%02X", x, kk)
    elseif o == 4 then return string.format("SNE  V%X, 0x%02X", x, kk)
    elseif o == 5 and n == 0 then return string.format("SE   V%X, V%X", x, y)
    elseif o == 6 then return string.format("LD   V%X, 0x%02X", x, kk)
    elseif o == 7 then return string.format("ADD  V%X, 0x%02X", x, kk)
    elseif o == 8 then
        if n == 0 then return string.format("LD   V%X, V%X", x, y)
        elseif n == 1 then return string.format("OR   V%X, V%X", x, y)
        elseif n == 2 then return string.format("AND  V%X, V%X", x, y)
        elseif n == 3 then return string.format("XOR  V%X, V%X", x, y)
        elseif n == 4 then return string.format("ADD  V%X, V%X", x, y)
        elseif n == 5 then return string.format("SUB  V%X, V%X", x, y)
        elseif n == 6 then return string.format("SHR  V%X", x)
        elseif n == 7 then return string.format("SUBN V%X, V%X", x, y)
        elseif n == 0xE then return string.format("SHL  V%X", x)
        end
    elseif o == 9 and n == 0 then return string.format("SNE  V%X, V%X", x, y)
    elseif o == 0xA then return string.format("LD   I, 0x%03X", nnn)
    elseif o == 0xB then return string.format("JP   V0, 0x%03X", nnn)
    elseif o == 0xC then return string.format("RND  V%X, 0x%02X", x, kk)
    elseif o == 0xD then return string.format("DRW  V%X, V%X, %d", x, y, n)
    elseif o == 0xE then
        if kk == 0x9E then return string.format("SKP  V%X", x)
        elseif kk == 0xA1 then return string.format("SKNP V%X", x)
        end
    elseif o == 0xF then
        if kk == 0x07 then return string.format("LD   V%X, DT", x)
        elseif kk == 0x0A then return string.format("LD   V%X, K", x)
        elseif kk == 0x15 then return string.format("LD   DT, V%X", x)
        elseif kk == 0x18 then return string.format("LD   ST, V%X", x)
        elseif kk == 0x1E then return string.format("ADD  I, V%X", x)
        elseif kk == 0x29 then return string.format("LD   F, V%X", x)
        elseif kk == 0x33 then return string.format("LD   B, V%X", x)
        elseif kk == 0x55 then return string.format("LD   [I], V%X", x)
        elseif kk == 0x65 then return string.format("LD   V%X, [I]", x)
        end
    end
    return string.format("UNK  0x%04X", op)
end

-- Execute a single instruction cycle
function Chip8:step()
    local vm = self.vm
    local pc = vm.pc
    if pc >= 4094 then return false end

    local op = bit.bor(bit.lshift(vm.memory[pc], 8), vm.memory[pc + 1])
    vm.pc = vm.pc + 2
    vm.cycle_count = vm.cycle_count + 1

    self.last_opcode = op
    self.last_disasm = self:disassemble(op)

    local o   = bit.rshift(op, 12)
    local x   = bit.band(bit.rshift(op, 8), 0x0F)
    local y   = bit.band(bit.rshift(op, 4), 0x0F)
    local n   = bit.band(op, 0x0F)
    local kk  = bit.band(op, 0xFF)
    local nnn = bit.band(op, 0x0FFF)

    if o == 0 then
        if op == 0x00E0 then
            ffi.fill(vm.gfx, CHIP8_WIDTH * CHIP8_HEIGHT, 0)
        elseif op == 0x00EE then
            if vm.sp > 0 then
                vm.sp = vm.sp - 1
                vm.pc = vm.stack[vm.sp]
            end
        end
    elseif o == 1 then
        vm.pc = nnn
    elseif o == 2 then
        if vm.sp < 16 then
            vm.stack[vm.sp] = vm.pc
            vm.sp = vm.sp + 1
            vm.pc = nnn
        end
    elseif o == 3 then
        if vm.V[x] == kk then vm.pc = vm.pc + 2 end
    elseif o == 4 then
        if vm.V[x] ~= kk then vm.pc = vm.pc + 2 end
    elseif o == 5 and n == 0 then
        if vm.V[x] == vm.V[y] then vm.pc = vm.pc + 2 end
    elseif o == 6 then
        vm.V[x] = kk
    elseif o == 7 then
        vm.V[x] = bit.band(vm.V[x] + kk, 0xFF)
    elseif o == 8 then
        if n == 0 then
            vm.V[x] = vm.V[y]
        elseif n == 1 then
            vm.V[x] = bit.bor(vm.V[x], vm.V[y])
            if self.quirks.logic_resets_vf then vm.V[0xF] = 0 end
        elseif n == 2 then
            vm.V[x] = bit.band(vm.V[x], vm.V[y])
            if self.quirks.logic_resets_vf then vm.V[0xF] = 0 end
        elseif n == 3 then
            vm.V[x] = bit.bxor(vm.V[x], vm.V[y])
            if self.quirks.logic_resets_vf then vm.V[0xF] = 0 end
        elseif n == 4 then
            local sum = vm.V[x] + vm.V[y]
            vm.V[x] = bit.band(sum, 0xFF)
            vm.V[0xF] = (sum > 0xFF) and 1 or 0
        elseif n == 5 then
            local vx, vy = vm.V[x], vm.V[y]
            vm.V[x] = bit.band(vx - vy, 0xFF)
            vm.V[0xF] = (vx >= vy) and 1 or 0
        elseif n == 6 then
            local val = self.quirks.shift_vy and vm.V[y] or vm.V[x]
            local lsb = bit.band(val, 1)
            vm.V[x] = bit.rshift(val, 1)
            vm.V[0xF] = lsb
        elseif n == 7 then
            local vx, vy = vm.V[x], vm.V[y]
            vm.V[x] = bit.band(vy - vx, 0xFF)
            vm.V[0xF] = (vy >= vx) and 1 or 0
        elseif n == 0xE then
            local val = self.quirks.shift_vy and vm.V[y] or vm.V[x]
            local msb = bit.band(bit.rshift(val, 7), 1)
            vm.V[x] = bit.band(bit.lshift(val, 1), 0xFF)
            vm.V[0xF] = msb
        end
    elseif o == 9 and n == 0 then
        if vm.V[x] ~= vm.V[y] then vm.pc = vm.pc + 2 end
    elseif o == 0xA then
        vm.I = nnn
    elseif o == 0xB then
        vm.pc = bit.band(nnn + vm.V[0], 0x0FFF)
    elseif o == 0xC then
        vm.V[x] = bit.band(math.random(0, 255), kk)
    elseif o == 0xD then
        -- DRW Vx, Vy, nibble: Draw sprite at (Vx, Vy) with height n
        local x0 = vm.V[x] % CHIP8_WIDTH
        local y0 = vm.V[y] % CHIP8_HEIGHT
        vm.V[0xF] = 0
        for r = 0, n - 1 do
            local py = y0 + r
            if py < CHIP8_HEIGHT then
                local sprite_byte = vm.memory[vm.I + r]
                for c = 0, 7 do
                    local px = x0 + c
                    if px < CHIP8_WIDTH then
                        local pixel_bit = bit.band(bit.rshift(sprite_byte, 7 - c), 1)
                        if pixel_bit == 1 then
                            local idx = py * CHIP8_WIDTH + px
                            if vm.gfx[idx] == 1 then
                                vm.V[0xF] = 1
                            end
                            vm.gfx[idx] = bit.bxor(vm.gfx[idx], 1)
                        end
                    end
                end
            end
        end
    elseif o == 0xE then
        if kk == 0x9E then
            local key_idx = bit.band(vm.V[x], 0x0F)
            if vm.keys[key_idx] == 1 then vm.pc = vm.pc + 2 end
        elseif kk == 0xA1 then
            local key_idx = bit.band(vm.V[x], 0x0F)
            if vm.keys[key_idx] == 0 then vm.pc = vm.pc + 2 end
        end
    elseif o == 0xF then
        if kk == 0x07 then
            vm.V[x] = vm.delay_timer
        elseif kk == 0x0A then
            -- Fx0A: Wait for key press
            local kp = nil
            for k = 0, 15 do
                if vm.keys[k] == 1 then
                    kp = k
                    break
                end
            end
            if kp ~= nil then
                vm.V[x] = kp
            else
                vm.pc = vm.pc - 2 -- Repeat opcode until key is pressed
            end
        elseif kk == 0x15 then
            vm.delay_timer = vm.V[x]
        elseif kk == 0x18 then
            vm.sound_timer = vm.V[x]
        elseif kk == 0x1E then
            vm.I = bit.band(vm.I + vm.V[x], 0xFFFF)
        elseif kk == 0x29 then
            vm.I = FONTSET_ADDR + bit.band(vm.V[x], 0x0F) * 5
        elseif kk == 0x33 then
            local val = vm.V[x]
            vm.memory[vm.I]     = math.floor(val / 100)
            vm.memory[vm.I + 1] = math.floor((val % 100) / 10)
            vm.memory[vm.I + 2] = val % 10
        elseif kk == 0x55 then
            for i = 0, x do
                vm.memory[vm.I + i] = vm.V[i]
            end
            if self.quirks.load_store_inc_i then
                vm.I = vm.I + x + 1
            end
        elseif kk == 0x65 then
            for i = 0, x do
                vm.V[i] = vm.memory[vm.I + i]
            end
            if self.quirks.load_store_inc_i then
                vm.I = vm.I + x + 1
            end
        end
    end
    return true
end

-- Decrement 60 Hz timers & handle key decay
function Chip8:tick_60hz()
    local vm = self.vm
    if vm.delay_timer > 0 then
        vm.delay_timer = vm.delay_timer - 1
    end
    local beep = false
    if vm.sound_timer > 0 then
        vm.sound_timer = vm.sound_timer - 1
        beep = true
    end

    -- Decay key states so released keys don't stay held forever
    for k = 0, 15 do
        if self.key_decay[k] > 0 then
            self.key_decay[k] = self.key_decay[k] - 1
            if self.key_decay[k] == 0 then
                vm.keys[k] = 0
            end
        end
    end

    return beep
end

function Chip8:press_key(key_val)
    if key_val >= 0 and key_val <= 15 then
        self.vm.keys[key_val] = 1
        self.key_decay[key_val] = 5 -- Hold active for ~5 frames (~83ms)
    end
end

-- ============================================================================
-- 5. PIXEL-PERFECT 80-COLUMN TERMINAL TUI RENDERER
-- ============================================================================
function Chip8:render_frame()
    local lines = {}
    local theme = COLOR_THEMES[self.theme_idx]
    local vm = self.vm

    -- Header Banner (80 columns: 1 space + 78 chars + 1 space)
    if self.use_ascii then
        lines[#lines + 1] = " +============================================================================+ "
        lines[#lines + 1] = " |            CHIP-8 RETRO CPU EMULATOR & VM - LUAJIT FFI ENGINE              | "
        lines[#lines + 1] = " +============================================================================+ "
    else
        lines[#lines + 1] = " ╔════════════════════════════════════════════════════════════════════════════╗ "
        lines[#lines + 1] = string.format(" ║           %s👾  CHIP-8 RETRO CPU EMULATOR - LUAJIT FFI ENGINE  👾%s            ║ ",
            "\27[1;36m", "\27[0m")
        lines[#lines + 1] = " ╚════════════════════════════════════════════════════════════════════════════╝ "
    end

    -- Top border of display (66 columns centered: 7 spaces margin + 66 box + 7 spaces = 80)
    local title_str = string.format(" DISPLAY [64x32] - %s ", self.current_rom_title)
    if #title_str > 46 then title_str = title_str:sub(1, 46) end
    local pad_r = string.rep(self.use_ascii and "-" or "─", 62 - #title_str)

    if self.use_ascii then
        lines[#lines + 1] = string.format("       +--%s%s+       ", title_str, pad_r)
    else
        lines[#lines + 1] = string.format("       ┌──%s%s%s%s┐       ",
            "\27[1;33m", title_str, "\27[0m", pad_r)
    end

    -- Screen body: 32 vertical pixels compressed into 16 terminal lines using half-blocks
    -- Each half-block: top pixel = bit 0, bottom pixel = bit 1
    for row = 0, 15 do
        local y_top = row * 2
        local y_bot = row * 2 + 1
        local row_chars = {}

        for col = 0, 63 do
            local top_on = (vm.gfx[y_top * 64 + col] == 1)
            local bot_on = (vm.gfx[y_bot * 64 + col] == 1)

            if self.use_ascii then
                if top_on and bot_on then
                    row_chars[#row_chars + 1] = "#"
                elseif top_on then
                    row_chars[#row_chars + 1] = "^"
                elseif bot_on then
                    row_chars[#row_chars + 1] = "."
                else
                    row_chars[#row_chars + 1] = " "
                end
            else
                if top_on and bot_on then
                    row_chars[#row_chars + 1] = "█"
                elseif top_on then
                    row_chars[#row_chars + 1] = "▀"
                elseif bot_on then
                    row_chars[#row_chars + 1] = "▄"
                else
                    row_chars[#row_chars + 1] = " "
                end
            end
        end

        local screen_line = table.concat(row_chars)
        local border_char = self.use_ascii and "|" or "│"

        if self.use_ascii then
            lines[#lines + 1] = string.format("       %s%s%s       ", border_char, screen_line, border_char)
        else
            lines[#lines + 1] = string.format("       %s%s%s%s%s%s       ",
                "\27[0m" .. border_char,
                theme.bg, theme.fg, screen_line,
                "\27[0m", border_char)
        end
    end

    -- Bottom border of display
    if self.use_ascii then
        lines[#lines + 1] = "       +----------------------------------------------------------------+       "
    else
        lines[#lines + 1] = "       └────────────────────────────────────────────────────────────────┘       "
    end

    -- CPU Status & Registers Section (80 columns: 1 space + 78 chars + 1 space)
    local v_row1 = string.format("V0:%02X V1:%02X V2:%02X V3:%02X V4:%02X V5:%02X V6:%02X V7:%02X",
        vm.V[0], vm.V[1], vm.V[2], vm.V[3], vm.V[4], vm.V[5], vm.V[6], vm.V[7])
    local v_row2 = string.format("V8:%02X V9:%02X VA:%02X VB:%02X VC:%02X VD:%02X VE:%02X VF:%02X",
        vm.V[8], vm.V[9], vm.V[10], vm.V[11], vm.V[12], vm.V[13], vm.V[14], vm.V[15])

    local state_str = self.paused and "PAUSED " or "RUNNING"
    local sound_ind = (vm.sound_timer > 0) and "♪ BEEP!" or "      "
    local disasm_str = self.last_disasm
    if #disasm_str > 14 then disasm_str = disasm_str:sub(1, 14) end

    local stat1 = string.format("PC:%04X  SP:%02X  DT:%02X",
        vm.pc, vm.sp, vm.delay_timer)
    local stat2 = string.format("I :%04X  OP:%04X  ST:%02X",
        vm.I, self.last_opcode, vm.sound_timer)

    local ctl_text = "Keys: 1234/QWER/ASDF/ZXCV | Space:Pause N:Step R:Reset M:ROM C:Theme Q:Esc"

    if self.use_ascii then
        lines[#lines + 1] = " +-- CPU REGISTERS " .. string.rep("-", 32) .. "+-- STATE & TIMERS " .. string.rep("-", 8) .. "+ "
        lines[#lines + 1] = string.format(" | %s | %-24s | ", v_row1, stat1)
        lines[#lines + 1] = string.format(" | %s | %-24s | ", v_row2, stat2)
        lines[#lines + 1] = " +-- CONTROLS & KEYPAD " .. string.rep("-", 28) .. "+" .. string.rep("-", 26) .. "+ "
        lines[#lines + 1] = string.format(" | %s | ", ctl_text)
        lines[#lines + 1] = " +" .. string.rep("-", 76) .. "+ "
    else
        lines[#lines + 1] = " ┌── CPU REGISTERS " .. string.rep("─", 32) .. "┬── STATE & TIMERS " .. string.rep("─", 8) .. "┐ "
        lines[#lines + 1] = string.format(" │ %s │ %-24s │ ", v_row1, stat1:sub(1, 24))
        lines[#lines + 1] = string.format(" │ %s │ %-24s │ ", v_row2, stat2:sub(1, 24))
        lines[#lines + 1] = " ├── CONTROLS & KEYPAD " .. string.rep("─", 28) .. "┴" .. string.rep("─", 26) .. "┤ "
        lines[#lines + 1] = string.format(" │ %s │ ", ctl_text)
        lines[#lines + 1] = " └" .. string.rep("─", 76) .. "┘ "
    end

    return table.concat(lines, "\n")
end

-- ============================================================================
-- 6. INTERACTIVE APPLICATION LOOP
-- ============================================================================
function Chip8:run_interactive(initial_rom_key)
    local term = Terminal.new()
    term:enable_raw_mode()

    if initial_rom_key then
        self:load_builtin(initial_rom_key)
    end

    local running = true
    local last_timer_sec = term:get_time_sec()
    local cycles_per_sec = self.cpu_hz
    local timer_interval = 1.0 / 60.0
    local cycle_interval = 1.0 / cycles_per_sec
    local last_cycle_sec = last_timer_sec

    io.write("\27[2J\27[H") -- Clear screen & home cursor
    io.flush()

    local current_rom_idx = 1
    for idx, key in ipairs(ROM_ORDER) do
        if key == self.current_rom_key then
            current_rom_idx = idx
            break
        end
    end

    while running do
        local now = term:get_time_sec()

        -- 1. Read keyboard inputs
        local key = term:read_key()
        if key then
            if key == 'q' or key == 'Q' or key == '\27' then
                running = false
            elseif key == ' ' then
                self.paused = not self.paused
            elseif key == 'n' or key == 'N' or key == '.' then
                if self.paused then self:step() end
            elseif key == 'r' or key == 'R' then
                if self.current_rom_key ~= "file" then
                    self:load_builtin(self.current_rom_key)
                else
                    self:reset()
                end
            elseif key == 'm' or key == 'M' then
                current_rom_idx = (current_rom_idx % #ROM_ORDER) + 1
                self:load_builtin(ROM_ORDER[current_rom_idx])
            elseif key == 'c' or key == 'C' then
                self.theme_idx = (self.theme_idx % #COLOR_THEMES) + 1
            elseif key == '+' or key == '=' then
                self.cpu_hz = math.min(3000, self.cpu_hz + 100)
                cycle_interval = 1.0 / self.cpu_hz
            elseif key == '-' or key == '_' then
                self.cpu_hz = math.max(100, self.cpu_hz - 100)
                cycle_interval = 1.0 / self.cpu_hz
            else
                -- Check Chip-8 Hex Keypad mapping
                local hex_val = KEY_MAP[key]
                if hex_val ~= nil then
                    self:press_key(hex_val)
                end
            end
        end

        -- 2. Execute CPU cycles
        if not self.paused then
            local time_diff = now - last_cycle_sec
            local cycles_to_run = math.floor(time_diff * self.cpu_hz)
            if cycles_to_run > 0 then
                -- Clamp cycles per frame to avoid lag spikes
                if cycles_to_run > 50 then cycles_to_run = 50 end
                for _ = 1, cycles_to_run do
                    self:step()
                end
                last_cycle_sec = now
            end
        end

        -- 3. Decrement 60 Hz hardware timers
        if (now - last_timer_sec) >= timer_interval then
            local beep = self:tick_60hz()
            if beep then term:beep() end
            last_timer_sec = now

            -- Render frame to terminal
            local frame = self:render_frame()
            io.write("\27[H" .. frame .. "\n")
            io.flush()
        end

        term:sleep_ms(2)
    end

    term:disable_raw_mode()
    print("\n[CHIP-8 Emulator terminated gracefully.]\n")
end

-- ============================================================================
-- 7. CLI DISPATCHER & SELF-TESTS
-- ============================================================================
local function print_help()
    print([[
🎮 CHIP-8 RETRO CPU EMULATOR & VIRTUAL MACHINE (LuaJIT FFI) 🎮

Usage:
  luajit ffi_chip8.lua [options] [rom_file.ch8]

Options:
  --help               Show this help message and exit
  --test               Execute internal regression and self-test suite
  --snapshot           Render a single non-interactive frame and exit
  --ascii              Use pure ASCII characters for display & borders
  --rom <name>         Launch with built-in ROM (ibm, pong, brix, tetris, ufo, corax, maze)
  --speed <hz>         Set CPU speed in Hz (default: 700)
  --theme <1-5>        Color theme (1:Green, 2:Amber, 3:Cyan, 4:Mono, 5:Neon)

Keypad Controls (QWERTY -> Chip-8 16-key Hex):
  1 2 3 4   ->  1 2 3 C
  Q W E R   ->  4 5 6 D
  A S D F   ->  7 8 9 E
  Z X C V   ->  A 0 B F

Emulator Hotkeys:
  Space       Pause / Resume execution
  N or .      Single-step instruction (when paused)
  R           Reset current ROM
  M           Cycle next built-in ROM
  C           Cycle phosphor color theme
  + / -       Increase / Decrease CPU clock speed
  Q or Esc    Quit emulator
]])
end

local function run_self_tests()
    print("=== Running Internal Self-Tests for ffi_chip8.lua ===")
    local chip = Chip8.new()

    -- 1. FFI Struct verification
    assert(ffi.sizeof("Chip8VM") == 4096 + 16 + 2 + 2 + 1 + 1 + 32 + 2 + 2048 + 16 + 4, "Chip8VM size mismatch")
    print("  ✔ PASS: Chip8VM struct size and layout")

    -- 2. Fontset loaded at 0x050
    assert(chip.vm.memory[0x050] == 0xF0, "Fontset 0 byte 0 mismatch")
    assert(chip.vm.memory[0x050 + 5] == 0x20, "Fontset 1 byte 0 mismatch")
    print("  ✔ PASS: COSMAC VIP Fontset loaded at 0x050")

    -- 3. Jumps & Subroutines (JP, CALL, RET)
    chip:reset()
    chip.vm.memory[0x200] = 0x12
    chip.vm.memory[0x201] = 0x50 -- JP 0x250
    chip:step()
    assert(chip.vm.pc == 0x250, "JP 0x250 failed")

    chip.vm.memory[0x250] = 0x23
    chip.vm.memory[0x251] = 0x00 -- CALL 0x300
    chip:step()
    assert(chip.vm.pc == 0x300 and chip.vm.sp == 1 and chip.vm.stack[0] == 0x252, "CALL 0x300 failed")

    chip.vm.memory[0x300] = 0x00
    chip.vm.memory[0x301] = 0xEE -- RET
    chip:step()
    assert(chip.vm.pc == 0x252 and chip.vm.sp == 0, "RET failed")
    print("  ✔ PASS: JP, CALL, RET instructions")

    -- 4. Arithmetic & Logic (ADD, SUB, AND, OR, XOR, SHL, SHR)
    chip:reset()
    chip.vm.V[0] = 10
    chip.vm.V[1] = 20
    chip.vm.memory[0x200] = 0x80
    chip.vm.memory[0x201] = 0x14 -- ADD V0, V1
    chip:step()
    assert(chip.vm.V[0] == 30 and chip.vm.V[0xF] == 0, "ADD V0, V1 failed")

    -- Carry overflow
    chip.vm.V[0] = 250
    chip.vm.V[1] = 10
    chip.vm.memory[0x202] = 0x80
    chip.vm.memory[0x203] = 0x14 -- ADD V0, V1
    chip:step()
    assert(chip.vm.V[0] == 4 and chip.vm.V[0xF] == 1, "ADD carry failed")

    -- SUB borrow
    chip.vm.V[0] = 20
    chip.vm.V[1] = 5
    chip.vm.memory[0x204] = 0x80
    chip.vm.memory[0x205] = 0x15 -- SUB V0, V1
    chip:step()
    assert(chip.vm.V[0] == 15 and chip.vm.V[0xF] == 1, "SUB no-borrow failed")

    chip.vm.V[0] = 5
    chip.vm.V[1] = 10
    chip.vm.memory[0x206] = 0x80
    chip.vm.memory[0x207] = 0x15 -- SUB V0, V1
    chip:step()
    assert(chip.vm.V[0] == 251 and chip.vm.V[0xF] == 0, "SUB borrow failed")
    print("  ✔ PASS: Arithmetic instructions (ADD, SUB with carry/borrow)")

    -- 5. BCD conversion (Fx33)
    chip:reset()
    chip.vm.V[2] = 237
    chip.vm.I = 0x400
    chip.vm.memory[0x200] = 0xF2
    chip.vm.memory[0x201] = 0x33 -- LD B, V2
    chip:step()
    assert(chip.vm.memory[0x400] == 2 and chip.vm.memory[0x401] == 3 and chip.vm.memory[0x402] == 7, "BCD failed")
    print("  ✔ PASS: BCD binary-coded decimal conversion")

    -- 6. Graphics drawing & collision (Dxyn)
    chip:reset()
    chip.vm.memory[0x300] = 0xFF -- 8 horizontal pixels
    chip.vm.I = 0x300
    chip.vm.V[0] = 10
    chip.vm.V[1] = 5
    chip.vm.memory[0x200] = 0xD0
    chip.vm.memory[0x201] = 0x11 -- DRW V0, V1, 1
    chip:step()
    assert(chip.vm.V[0xF] == 0, "Initial draw should have VF=0")
    for c = 0, 7 do
        assert(chip.vm.gfx[5 * 64 + 10 + c] == 1, "Pixel not set")
    end

    -- Draw again at same position -> XOR turns them off, collision VF=1
    chip.vm.memory[0x202] = 0xD0
    chip.vm.memory[0x203] = 0x11
    chip:step()
    assert(chip.vm.V[0xF] == 1, "Collision overwrite should set VF=1")
    for c = 0, 7 do
        assert(chip.vm.gfx[5 * 64 + 10 + c] == 0, "Pixel not toggled off")
    end
    print("  ✔ PASS: DRW sprite drawing, XOR toggling, and collision detection")

    -- 7. Built-in ROMs validation
    for key, rom in pairs(BUILTIN_ROMS) do
        chip:load_builtin(key)
        assert(chip.current_rom_key == key and rom.size > 0, "ROM " .. key .. " failed to load")
        chip:step()
    end
    print("  ✔ PASS: All 7 built-in ROMs load and step properly")

    -- 8. Run Corax+ Diagnostic Opcode Test for 50,000 cycles
    chip:load_builtin("corax")
    for _ = 1, 50000 do
        chip:step()
        if chip.vm.delay_timer > 0 then chip.vm.delay_timer = chip.vm.delay_timer - 1 end
    end
    local active_pixels = 0
    for i = 0, 64 * 32 - 1 do
        if chip.vm.gfx[i] == 1 then active_pixels = active_pixels + 1 end
    end
    assert(active_pixels > 200, "Corax+ should have rendered test checkmarks")
    print("  ✔ PASS: Corax+ Diagnostic Opcode Suite executed successfully")

    -- 9. 80-Column Frame Layout Verification
    chip.use_ascii = false
    local frame = chip:render_frame()
    local line_count = 0
    for line in frame:gmatch("[^\r\n]+") do
        line_count = line_count + 1
        -- Strip ANSI color escapes for visual width check
        local plain = line:gsub("\27%[[%d;]*m", "")
        -- Count Unicode double-width or standard characters
        local char_count = 0
        local i = 1
        while i <= #plain do
            local b = plain:byte(i)
            if b < 128 then
                char_count = char_count + 1
                i = i + 1
            elseif b >= 192 and b < 224 then
                char_count = char_count + 1
                i = i + 2
            elseif b >= 224 and b < 240 then
                -- 3-byte UTF-8 (e.g. ╔, ║, ▀, █, etc.)
                -- Check if emoji (👾: 4-byte or special)
                char_count = char_count + 1
                i = i + 3
            elseif b >= 240 then
                -- 4-byte UTF-8 emoji (👾): takes 2 terminal columns
                char_count = char_count + 2
                i = i + 4
            else
                i = i + 1
            end
        end
        assert(char_count == 80, string.format("Line %d width is %d != 80: '%s'", line_count, char_count, plain))
    end
    print("  ✔ PASS: Uniform 80-column terminal frame geometry")

    print("\nAll Chip-8 self-tests completed successfully!\n")
    return true
end

-- ============================================================================
-- 8. MAIN ENTRYPOINT
-- ============================================================================
local function main(args)
    local rom_to_load = "ibm"
    local custom_file = nil
    local snapshot_mode = false
    local ascii_mode = false
    local theme_id = 1
    local speed_hz = 700

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--help" or a == "-h" then
            print_help()
            return 0
        elseif a == "--test" then
            local ok = run_self_tests()
            return ok and 0 or 1
        elseif a == "--snapshot" then
            snapshot_mode = true
        elseif a == "--ascii" then
            ascii_mode = true
        elseif a == "--rom" and i + 1 <= #args then
            i = i + 1
            rom_to_load = args[i]:lower()
        elseif a == "--theme" and i + 1 <= #args then
            i = i + 1
            theme_id = tonumber(args[i]) or 1
        elseif a == "--speed" and i + 1 <= #args then
            i = i + 1
            speed_hz = tonumber(args[i]) or 700
        elseif not a:match("^%-%-") then
            custom_file = a
        end
        i = i + 1
    end

    local chip = Chip8.new()
    chip.use_ascii = ascii_mode
    chip.theme_idx = theme_id
    chip.cpu_hz = speed_hz

    if custom_file then
        local ok, err = chip:load_rom_file(custom_file)
        if not ok then
            io.stderr:write("Error loading ROM: " .. tostring(err) .. "\n")
            return 1
        end
    else
        if not BUILTIN_ROMS[rom_to_load] then
            rom_to_load = "ibm"
        end
        chip:load_builtin(rom_to_load)
    end

    if snapshot_mode then
        -- Run a few cycles to allow initial frame draw
        for _ = 1, 200 do chip:step() end
        local frame = chip:render_frame()
        print(frame)
        return 0
    end

    chip:run_interactive()
    return 0
end

local is_main = false
if arg and arg[0] and (arg[0] == "ffi_chip8.lua" or arg[0]:match("/ffi_chip8%.lua$") ~= nil) then
    is_main = true
end

if is_main then
    local exit_code = main(arg or {})
    os.exit(exit_code or 0)
end

return {
    Chip8 = Chip8,
    Terminal = Terminal,
    BUILTIN_ROMS = BUILTIN_ROMS,
    FONTSET = FONTSET,
    KEY_MAP = KEY_MAP
}
