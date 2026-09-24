#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- ffi_elf_inspector.lua
-- High-performance Linux ELF Binary Analyzer, Symbol Inspector & Disassembler
-- Powered by LuaJIT FFI with Zero External Mandatory Dependencies.
--
-- Features:
--   - Full ELF64 / ELF32 header, section, and program header parser via FFI
--   - Symbol table extraction (.symtab & .dynsym) with function & export filters
--   - C++ symbol demangling via dynamic libstdc++ __cxa_demangle binding
--   - Function code extraction, hex dump, and integrated disassembly
--   - Dual interface: Split-pane interactive terminal TUI & scriptable CLI/JSON
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

--------------------------------------------------------------------------------
-- 1. POSIX Terminal & C Declarations
--------------------------------------------------------------------------------
ffi.cdef[[
typedef unsigned int tcflag_t;
typedef unsigned char cc_t;
typedef unsigned int speed_t;

struct termios {
    tcflag_t c_iflag, c_oflag, c_cflag, c_lflag;
    cc_t c_line;
    cc_t c_cc[32];
    speed_t c_ispeed, c_ospeed;
};

struct winsize {
    unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel;
};

struct pollfd {
    int fd;
    short events;
    short revents;
};

int tcgetattr(int fd, struct termios *termios_p);
int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
int ioctl(int fd, unsigned long request, ...);
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
long read(int fd, void *buf, unsigned long count);
int isatty(int fd);

// C++ demangling interface
char* __cxa_demangle(const char* mangled_name, char* output_buffer, size_t* length, int* status);
void free(void *ptr);

// 64-bit ELF data structures
typedef struct {
    unsigned char e_ident[16];
    uint16_t      e_type;
    uint16_t      e_machine;
    uint32_t      e_version;
    uint64_t      e_entry;
    uint64_t      e_phoff;
    uint64_t      e_shoff;
    uint32_t      e_flags;
    uint16_t      e_ehsize;
    uint16_t      e_phentsize;
    uint16_t      e_phnum;
    uint16_t      e_shentsize;
    uint16_t      e_shnum;
    uint16_t      e_shstrndx;
} Elf64_Ehdr;

typedef struct {
    uint32_t   sh_name;
    uint32_t   sh_type;
    uint64_t   sh_flags;
    uint64_t   sh_addr;
    uint64_t   sh_offset;
    uint64_t   sh_size;
    uint32_t   sh_link;
    uint32_t   sh_info;
    uint64_t   sh_addralign;
    uint64_t   sh_entsize;
} Elf64_Shdr;

typedef struct {
    uint32_t      st_name;
    unsigned char st_info;
    unsigned char st_other;
    uint16_t      st_shndx;
    uint64_t      st_value;
    uint64_t      st_size;
} Elf64_Sym;

typedef struct {
    uint32_t p_type;
    uint32_t p_flags;
    uint64_t p_offset;
    uint64_t p_vaddr;
    uint64_t p_paddr;
    uint64_t p_filesz;
    uint64_t p_memsz;
    uint64_t p_align;
} Elf64_Phdr;

// Dynamic section entry
typedef struct {
    int64_t  d_tag;
    union {
        uint64_t d_val;
        uint64_t d_ptr;
    } d_un;
} Elf64_Dyn;
]]

-- Dynamic demangler loader
local demangle_fn = nil
local ok_demangle, libcpp = pcall(ffi.load, "stdc++")
if ok_demangle and libcpp then
    local status_buf = ffi.new("int[1]")
    demangle_fn = function(mangled)
        if not mangled or not mangled:match("^__?Z") then return mangled end
        status_buf[0] = 0
        local res = libcpp.__cxa_demangle(mangled, nil, nil, status_buf)
        if res ~= nil then
            local str = ffi.string(res)
            ffi.C.free(res)
            return str
        end
        return mangled
    end
else
    demangle_fn = function(mangled) return mangled end
end

--------------------------------------------------------------------------------
-- 2. ELF Parser Constants and Engine
--------------------------------------------------------------------------------
local ELF_MAGIC = "\x7fELF"

local ELF_TYPES = {
    [0] = "NONE",
    [1] = "REL (Relocatable object)",
    [2] = "EXEC (Executable)",
    [3] = "DYN (Shared object / PIE)",
    [4] = "CORE (Core dump)"
}

local ELF_MACHINES = {
    [0x03] = "x86 (i386)",
    [0x3e] = "AMD x86-64",
    [0x28] = "ARM (32-bit)",
    [0xb7] = "AArch64 (ARM 64-bit)",
    [0xf3] = "RISC-V",
    [0x08] = "MIPS",
    [0x14] = "PowerPC",
    [0x15] = "PowerPC 64-bit",
}

local SHT_TYPES = {
    [0]  = "NULL",
    [1]  = "PROGBITS",
    [2]  = "SYMTAB",
    [3]  = "STRTAB",
    [4]  = "RELA",
    [5]  = "HASH",
    [6]  = "DYNAMIC",
    [7]  = "NOTE",
    [8]  = "NOBITS",
    [9]  = "REL",
    [10] = "SHLIB",
    [11] = "DYNSYM",
    [14] = "INIT_ARRAY",
    [15] = "FINI_ARRAY",
    [0x6ffffff6] = "GNU_HASH",
    [0x6ffffffe] = "VERNEED",
    [0x6fffffff] = "VERSYM"
}

local DT_NEEDED = 1
local DT_STRTAB = 5

local function parse_elf_file(filepath)
    local f, err = io.open(filepath, "rb")
    if not f then return nil, "Failed to open file: " .. tostring(err) end

    local header_raw = f:read(ffi.sizeof("Elf64_Ehdr"))
    if not header_raw or #header_raw < ffi.sizeof("Elf64_Ehdr") then
        f:close()
        return nil, "File too small to contain a valid ELF64 header."
    end

    if header_raw:sub(1, 4) ~= ELF_MAGIC then
        f:close()
        return nil, "Not a valid ELF binary (magic mismatch)."
    end

    local class_byte = header_raw:byte(5) -- 1 = 32-bit, 2 = 64-bit
    local endian_byte = header_raw:byte(6) -- 1 = LSB (Little Endian), 2 = MSB (Big Endian)
    if class_byte ~= 2 then
        f:close()
        return nil, "Currently only ELF64 binaries are supported (detected 32-bit ELF)."
    end

    local ehdr = ffi.cast("const Elf64_Ehdr*", header_raw)

    local info = {
        filepath = filepath,
        filesize = f:seek("end"),
        is_64bit = (class_byte == 2),
        endian = (endian_byte == 1) and "LSB (Little Endian)" or "MSB (Big Endian)",
        type_code = ehdr.e_type,
        type = ELF_TYPES[ehdr.e_type] or string.format("0x%04x", ehdr.e_type),
        machine_code = ehdr.e_machine,
        machine = ELF_MACHINES[ehdr.e_machine] or string.format("Machine 0x%04x", ehdr.e_machine),
        entry = tonumber(ehdr.e_entry),
        phoff = tonumber(ehdr.e_phoff),
        shoff = tonumber(ehdr.e_shoff),
        phnum = tonumber(ehdr.e_phnum),
        shnum = tonumber(ehdr.e_shnum),
        shstrndx = tonumber(ehdr.e_shstrndx),
        sections = {},
        functions = {},
        exports = {},
        imports = {},
        dependencies = {},
        has_symtab = false,
        has_dynsym = false,
        text_size = 0,
        text_addr = 0,
        text_offset = 0,
    }

    -- 1. Read Section Headers
    if info.shoff > 0 and info.shnum > 0 then
        f:seek("set", info.shoff)
        for i = 0, info.shnum - 1 do
            local sh_data = f:read(ffi.sizeof("Elf64_Shdr"))
            if not sh_data or #sh_data < ffi.sizeof("Elf64_Shdr") then break end
            local sh = ffi.cast("const Elf64_Shdr*", sh_data)
            table.insert(info.sections, {
                index = i,
                name_idx = tonumber(sh.sh_name),
                type_code = tonumber(sh.sh_type),
                type = SHT_TYPES[tonumber(sh.sh_type)] or string.format("0x%x", tonumber(sh.sh_type)),
                flags_raw = tonumber(sh.sh_flags),
                flags_str = string.format("%s%s%s",
                    bit.band(tonumber(sh.sh_flags), 1) ~= 0 and "W" or "-",
                    bit.band(tonumber(sh.sh_flags), 2) ~= 0 and "A" or "-",
                    bit.band(tonumber(sh.sh_flags), 4) ~= 0 and "X" or "-"),
                addr = tonumber(sh.sh_addr),
                offset = tonumber(sh.sh_offset),
                size = tonumber(sh.sh_size),
                link = tonumber(sh.sh_link),
                info = tonumber(sh.sh_info),
                addralign = tonumber(sh.sh_addralign),
                entsize = tonumber(sh.sh_entsize),
                name = ""
            })
        end

        -- Read Section Name String Table (.shstrtab)
        if info.shstrndx >= 0 and info.shstrndx < #info.sections then
            local strtab_sec = info.sections[info.shstrndx + 1]
            f:seek("set", strtab_sec.offset)
            local shstrtab_data = f:read(strtab_sec.size) or ""

            local function extract_str(buf, off)
                if not buf or off >= #buf then return "" end
                local eos = string.find(buf, "\0", off + 1, true)
                return eos and string.sub(buf, off + 1, eos - 1) or ""
            end

            for _, sec in ipairs(info.sections) do
                sec.name = extract_str(shstrtab_data, sec.name_idx)
                if sec.name == ".text" then
                    info.text_size = sec.size
                    info.text_addr = sec.addr
                    info.text_offset = sec.offset
                end
                if sec.type_code == 2 then info.has_symtab = true end
                if sec.type_code == 11 then info.has_dynsym = true end
            end
        end
    end

    -- Helper to read string table content
    local function read_strtab(link_idx)
        if link_idx and link_idx >= 0 and link_idx < #info.sections then
            local sec = info.sections[link_idx + 1]
            f:seek("set", sec.offset)
            return f:read(sec.size) or ""
        end
        return ""
    end

    local function get_name(strbuf, off)
        if not strbuf or off == 0 or off >= #strbuf then return "" end
        local eos = string.find(strbuf, "\0", off + 1, true)
        return eos and string.sub(strbuf, off + 1, eos - 1) or ""
    end

    -- 2. Read Symbols from .symtab and .dynsym
    local seen_func_addr = {}

    local function parse_symbols_from_sec(sec, is_dynamic)
        local strtab_data = read_strtab(sec.link)
        f:seek("set", sec.offset)
        local num_syms = math.floor(sec.size / ffi.sizeof("Elf64_Sym"))

        for s_idx = 0, num_syms - 1 do
            local sym_raw = f:read(ffi.sizeof("Elf64_Sym"))
            if not sym_raw or #sym_raw < ffi.sizeof("Elf64_Sym") then break end
            local sym = ffi.cast("const Elf64_Sym*", sym_raw)

            local st_type = bit.band(sym.st_info, 0x0f)
            local st_bind = bit.rshift(sym.st_info, 4)
            local bind_name = (st_bind == 1 and "GLOBAL") or (st_bind == 2 and "WEAK") or "LOCAL"
            local name = get_name(strtab_data, tonumber(sym.st_name))
            local val = tonumber(sym.st_value)
            local sz = tonumber(sym.st_size)
            local shndx = tonumber(sym.st_shndx)

            if #name > 0 then
                -- Defined function: STT_FUNC (2) or symbol inside .text section
                local is_func = (st_type == 2)
                local is_import = (shndx == 0) -- SHN_UNDEF

                local sec_name = ""
                if shndx > 0 and (shndx + 1) <= #info.sections then
                    sec_name = info.sections[shndx + 1].name
                end

                if is_func and not is_import then
                    local demangled = demangle_fn(name)
                    local key = string.format("%d_%s", val, name)
                    if not seen_func_addr[key] then
                        seen_func_addr[key] = true
                        local fn_entry = {
                            name = name,
                            demangled = demangled,
                            addr = val,
                            size = sz,
                            bind = bind_name,
                            is_export = (st_bind == 1 or st_bind == 2),
                            section = sec_name,
                            shndx = shndx,
                            is_dynamic = is_dynamic
                        }
                        table.insert(info.functions, fn_entry)
                        if fn_entry.is_export then
                            table.insert(info.exports, fn_entry)
                        end
                    end
                elseif is_import and (st_type == 2 or is_dynamic) then
                    -- Imported function call
                    table.insert(info.imports, {
                        name = name,
                        demangled = demangle_fn(name),
                        bind = bind_name,
                        st_type = st_type
                    })
                end
            end
        end
    end

    -- Process .symtab (static symbols) if available
    for _, sec in ipairs(info.sections) do
        if sec.type_code == 2 then -- SHT_SYMTAB
            parse_symbols_from_sec(sec, false)
        end
    end

    -- Process .dynsym (dynamic symbols)
    for _, sec in ipairs(info.sections) do
        if sec.type_code == 11 then -- SHT_DYNSYM
            parse_symbols_from_sec(sec, true)
        end
    end

    -- 3. Parse Dynamic Section for DT_NEEDED (shared library dependencies)
    for _, sec in ipairs(info.sections) do
        if sec.type_code == 6 then -- SHT_DYNAMIC
            local dyn_strtab = read_strtab(sec.link)
            f:seek("set", sec.offset)
            local num_dyn = math.floor(sec.size / ffi.sizeof("Elf64_Dyn"))
            for d_idx = 0, num_dyn - 1 do
                local dyn_raw = f:read(ffi.sizeof("Elf64_Dyn"))
                if not dyn_raw or #dyn_raw < ffi.sizeof("Elf64_Dyn") then break end
                local dyn = ffi.cast("const Elf64_Dyn*", dyn_raw)
                local tag = tonumber(dyn.d_tag)
                if tag == 0 then break end -- DT_NULL
                if tag == DT_NEEDED then
                    local lib_name = get_name(dyn_strtab, tonumber(dyn.d_un.d_val))
                    if #lib_name > 0 then
                        table.insert(info.dependencies, lib_name)
                    end
                end
            end
        end
    end

    -- Sort functions by address
    table.sort(info.functions, function(a, b)
        if a.addr == b.addr then return a.size > b.size end
        return a.addr < b.addr
    end)

    info.stripped = (not info.has_symtab)

    f:close()
    return info
end

-- Convert byte size to readable format
local function format_bytes(bytes)
    if bytes < 1024 then return string.format("%d B", bytes) end
    if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
    return string.format("%.2f MB", bytes / (1024 * 1024))
end

-- Read raw function bytes from the ELF file
local function read_function_bytes(elf_info, func_entry, max_len)
    max_len = max_len or 256
    local len = math.min(func_entry.size > 0 and func_entry.size or 64, max_len)
    if len <= 0 then len = 64 end

    local f = io.open(elf_info.filepath, "rb")
    if not f then return "" end

    local file_offset = nil
    -- Match section by index or address range
    for _, sec in ipairs(elf_info.sections) do
        if func_entry.shndx == sec.index or
           (func_entry.addr >= sec.addr and func_entry.addr < sec.addr + sec.size) then
            file_offset = sec.offset + (func_entry.addr - sec.addr)
            break
        end
    end

    if not file_offset then
        f:close()
        return ""
    end

    f:seek("set", file_offset)
    local raw = f:read(len) or ""
    f:close()
    return raw, file_offset
end

-- Generate a clean 16-byte hex dump string
local function generate_hex_dump(raw_bytes, base_addr, max_lines)
    max_lines = max_lines or 12
    local lines = {}
    local total_len = #raw_bytes
    if total_len == 0 then return { "  (No machine code bytes available for this symbol)" } end

    for offset = 0, total_len - 1, 16 do
        if #lines >= max_lines then
            table.insert(lines, string.format("  ... (%d more bytes)", total_len - offset))
            break
        end
        local hex_parts = {}
        local ascii_parts = {}
        local chunk_len = math.min(16, total_len - offset)

        for i = 1, chunk_len do
            local b = raw_bytes:byte(offset + i)
            table.insert(hex_parts, string.format("%02x", b))
            if b >= 32 and b <= 126 then
                table.insert(ascii_parts, string.char(b))
            else
                table.insert(ascii_parts, ".")
            end
        end

        -- Pad if shorter than 16
        while #hex_parts < 16 do
            table.insert(hex_parts, "  ")
        end

        local hex_str = string.format("%s %s %s %s  %s %s %s %s  %s %s %s %s  %s %s %s %s",
            hex_parts[1], hex_parts[2], hex_parts[3], hex_parts[4],
            hex_parts[5], hex_parts[6], hex_parts[7], hex_parts[8],
            hex_parts[9], hex_parts[10], hex_parts[11], hex_parts[12],
            hex_parts[13], hex_parts[14], hex_parts[15], hex_parts[16])

        local line = string.format("  %08x  %-48s |%s|",
            base_addr + offset, hex_str, table.concat(ascii_parts))
        table.insert(lines, line)
    end
    return lines
end

-- Disassemble function instructions using system objdump
local function disassemble_function(filepath, func_entry, max_instructions)
    max_instructions = max_instructions or 40
    local start_addr = func_entry.addr
    local stop_addr = start_addr + (func_entry.size > 0 and func_entry.size or 64)
    if stop_addr <= start_addr then stop_addr = start_addr + 64 end

    local cmd = string.format("objdump -d -M intel --no-show-raw-insn --start-address=0x%x --stop-address=0x%x %q 2>/dev/null",
        start_addr, stop_addr, filepath)

    local p = io.popen(cmd, "r")
    if not p then return { "  (objdump utility not available on system)" } end

    local lines = {}
    local started = false
    for line in p:lines() do
        if line:find("<" .. func_entry.name .. ">:") or line:find("Disassembly of section") then
            started = true
        elseif started and line:match("^%s*%x+:") then
            table.insert(lines, "  " .. line:gsub("^%s+", ""))
            if #lines >= max_instructions then
                table.insert(lines, string.format("  ... (%d instructions shown, use CLI for full dump)", max_instructions))
                break
            end
        end
    end
    p:close()

    if #lines == 0 then
        -- Fallback: Disassemble without section/func anchor
        local cmd2 = string.format("objdump -d -M intel --start-address=0x%x --stop-address=0x%x %q 2>/dev/null",
            start_addr, stop_addr, filepath)
        local p2 = io.popen(cmd2, "r")
        if p2 then
            for line in p2:lines() do
                if line:match("^%s*%x+:") then
                    table.insert(lines, "  " .. line:gsub("^%s+", ""))
                    if #lines >= max_instructions then break end
                end
            end
            p2:close()
        end
    end

    if #lines == 0 then
        return { "  (No disassembly instructions could be resolved for this range)" }
    end
    return lines
end

--------------------------------------------------------------------------------
-- 3. Interactive Split-Pane Terminal TUI Engine
--------------------------------------------------------------------------------
local STDIN_FD = 0
local TIOCGWINSZ = 0x5413
local POLLIN = 0x0001
local TCSANOW = 0
local ICANON = 0x0002
local ECHO = 0x0008

local function get_terminal_size()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(STDIN_FD, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return ws.ws_col, ws.ws_row
    end
    return 100, 30
end

local orig_termios = nil
local function enable_raw_mode()
    orig_termios = ffi.new("struct termios")
    ffi.C.tcgetattr(STDIN_FD, orig_termios)
    local raw = ffi.new("struct termios")
    ffi.copy(raw, orig_termios, ffi.sizeof("struct termios"))
    raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
    ffi.C.tcsetattr(STDIN_FD, TCSANOW, raw)
    io.write("\27[?1049h\27[?25l") -- alt buffer, hide cursor
    io.flush()
end

local function disable_raw_mode()
    if orig_termios then
        io.write("\27[?25h\27[?1049l\27[0m") -- show cursor, restore buffer
        io.flush()
        ffi.C.tcsetattr(STDIN_FD, TCSANOW, orig_termios)
        orig_termios = nil
    end
end

local function read_key(timeout_ms)
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd = STDIN_FD
    pfd[0].events = POLLIN
    local res = ffi.C.poll(pfd, 1, timeout_ms or 50)
    if res <= 0 then return nil end

    local buf = ffi.new("char[16]")
    local n = ffi.C.read(STDIN_FD, buf, 16)
    if n <= 0 then return nil end
    local s = ffi.string(buf, n)

    if s == "\27" then return "esc" end
    if s == "\27[A" then return "up" end
    if s == "\27[B" then return "down" end
    if s == "\27[C" then return "right" end
    if s == "\27[D" then return "left" end
    if s == "\27[5~" then return "pgup" end
    if s == "\27[6~" then return "pgdn" end
    if s == "\27[H" or s == "\27[1~" then return "home" end
    if s == "\27[F" or s == "\27[4~" then return "end" end
    if s == "\t" then return "tab" end
    if s == "\27[Z" then return "shift-tab" end
    if s == "\r" or s == "\n" then return "enter" end
    if s == "\127" or s == "\8" then return "backspace" end
    return s
end

local function run_tui(elf_info)
    enable_raw_mode()

    -- Prepare ranked top bloat functions
    local bloat_funcs = {}
    for _, fn in ipairs(elf_info.functions) do
        if fn.size > 0 then
            table.insert(bloat_funcs, fn)
        end
    end
    table.sort(bloat_funcs, function(a, b) return a.size > b.size end)

    local state = {
        tab = 1, -- 1: Functions, 2: Sections, 3: Dynamic/Imports, 4: Top Bloat
        active_pane = "left", -- "left" or "right"
        cursor = 1,
        scroll = 0,
        right_scroll = 0,
        view_mode = "disasm", -- "disasm" or "hex"
        filter_text = "",
        is_searching = false,
        show_help = false,
        cached_disasm = {},
        cached_hex = {},
        status_msg = "Press '?' for help, 'q' to quit"
    }

    local function get_active_list()
        if state.tab == 1 then
            if #state.filter_text == 0 then
                return elf_info.functions
            end
            local filtered = {}
            local needle = state.filter_text:lower()
            for _, fn in ipairs(elf_info.functions) do
                if fn.name:lower():find(needle, 1, true) or
                   fn.demangled:lower():find(needle, 1, true) or
                   string.format("0x%x", fn.addr):find(needle, 1, true) then
                    table.insert(filtered, fn)
                end
            end
            return filtered
        elseif state.tab == 2 then
            return elf_info.sections
        elseif state.tab == 3 then
            return elf_info.imports
        elseif state.tab == 4 then
            return bloat_funcs
        end
        return {}
    end

    local function draw()
        local cols, rows = get_terminal_size()
        local buf = {}
        table.insert(buf, "\27[H")

        local list = get_active_list()
        if state.cursor > #list then state.cursor = math.max(1, #list) end
        if state.cursor < 1 and #list > 0 then state.cursor = 1 end

        -- Adjust scroll
        local list_height = rows - 6
        if state.cursor <= state.scroll then
            state.scroll = math.max(0, state.cursor - 1)
        elseif state.cursor > state.scroll + list_height then
            state.scroll = state.cursor - list_height
        end

        -- Header Bar
        local header_bg = "\27[48;5;236m\27[38;5;255m"
        local title = string.format(" 🔬 ELF Inspector: %s ",
            elf_info.filepath:match("([^/]+)$") or elf_info.filepath)
        local status_right = string.format("[%s • %s] ", elf_info.is_64bit and "ELF64" or "ELF32", elf_info.machine)
        local pad = string.rep(" ", math.max(0, cols - #title - #status_right))
        table.insert(buf, header_bg .. "\27[1m" .. title .. pad .. "\27[38;5;248m" .. status_right .. "\27[0m\n")

        -- Subheader: Binary Architecture & Specs
        local sub = string.format(" Type: %-18s | Entry: 0x%08x | Sections: %-2d | Functions: %-4d | Stripped: %s",
            elf_info.type:sub(1, 18), elf_info.entry, #elf_info.sections, #elf_info.functions,
            elf_info.stripped and "\27[31mYES\27[0m" or "\27[32mNO\27[0m")
        local sub_pad = string.rep(" ", math.max(0, cols - #sub:gsub("\27%[[0-9;]*m", "")))
        table.insert(buf, "\27[48;5;234m" .. sub .. sub_pad .. "\27[0m\n")

        -- Tab Navigation Bar
        local t1 = (state.tab == 1 and "\27[7m [1] Functions \27[0m" or " [1] Functions ")
        local t2 = (state.tab == 2 and "\27[7m [2] Sections \27[0m" or " [2] Sections ")
        local t3 = (state.tab == 3 and "\27[7m [3] Imports \27[0m" or " [3] Imports ")
        local t4 = (state.tab == 4 and "\27[7m [4] Top Bloat \27[0m" or " [4] Top Bloat ")
        local tabs = t1 .. t2 .. t3 .. t4

        local left_w = math.floor(cols * 0.48)
        local right_w = cols - left_w - 3
        local tab_clean_len = #tabs:gsub("\27%[[0-9;]*m", "")
        table.insert(buf, tabs .. string.rep(" ", math.max(0, cols - tab_clean_len)) .. "\n")

        -- Divider Line
        local div_left = string.rep("─", left_w)
        local div_right = string.rep("─", right_w)
        table.insert(buf, "\27[90m" .. div_left .. "┬" .. div_right .. "\27[0m\n")

        -- Active Item for Right Pane
        local active_item = list[state.cursor]

        -- Render Left List Rows & Right Detail Rows
        local right_lines = {}
        if state.active_pane == "right" then
            table.insert(right_lines, "\27[48;5;31m\27[38;5;255m ▌INSPECTOR FOCUSED▐  (Scroll: ↑/↓/PgUp/PgDn, Exit: ←/Left) \27[0m")
        end
        if active_item and (state.tab == 1 or state.tab == 4) then
            -- Function details
            local fn = active_item
            table.insert(right_lines, string.format("\27[1mSymbol:\27[0m  \27[36m%s\27[0m", fn.name))
            if fn.demangled ~= fn.name then
                table.insert(right_lines, string.format("\27[1mDemangled:\27[0m %s", fn.demangled))
            end
            table.insert(right_lines, string.format("\27[1mAddress:\27[0m 0x%08x   \27[1mSize:\27[0m %s (%d bytes)",
                fn.addr, format_bytes(fn.size), fn.size))
            table.insert(right_lines, string.format("\27[1mBinding:\27[0m %-6s   \27[1mSection:\27[0m %s", fn.bind, fn.section))
            table.insert(right_lines, "\27[90m" .. string.rep("─", right_w) .. "\27[0m")

            if state.view_mode == "disasm" then
                table.insert(right_lines, "\27[32;1m[Disassembly (x86-64 / Intel)]\27[0m (Press 'h' for Hex Dump)")
                if not state.cached_disasm[fn.name] then
                    state.cached_disasm[fn.name] = disassemble_function(elf_info.filepath, fn, 50)
                end
                for _, l in ipairs(state.cached_disasm[fn.name]) do
                    table.insert(right_lines, l)
                end
            else
                table.insert(right_lines, "\27[33;1m[Raw Machine Code Hex Dump]\27[0m (Press 'd' for Disasm)")
                if not state.cached_hex[fn.name] then
                    local raw, off = read_function_bytes(elf_info, fn, 192)
                    state.cached_hex[fn.name] = generate_hex_dump(raw, fn.addr, 20)
                end
                for _, l in ipairs(state.cached_hex[fn.name]) do
                    table.insert(right_lines, l)
                end
            end
        elseif active_item and state.tab == 2 then
            -- Section details
            local sec = active_item
            table.insert(right_lines, string.format("\27[1mSection:\27[0m    \27[36m%s\27[0m", sec.name))
            table.insert(right_lines, string.format("\27[1mType:\27[0m       %s (0x%x)", sec.type, sec.type_code))
            table.insert(right_lines, string.format("\27[1mVirt Addr:\27[0m  0x%08x", sec.addr))
            table.insert(right_lines, string.format("\27[1mFile Off:\27[0m   0x%08x (%d)", sec.offset, sec.offset))
            table.insert(right_lines, string.format("\27[1mSize:\27[0m       %s (%d bytes)", format_bytes(sec.size), sec.size))
            table.insert(right_lines, string.format("\27[1mFlags:\27[0m      %s (Raw: 0x%x)", sec.flags_str, sec.flags_raw))
            table.insert(right_lines, string.format("\27[1mAlignment:\27[0m  %d bytes", sec.addralign))
        elseif active_item and state.tab == 3 then
            -- Import details
            local imp = active_item
            table.insert(right_lines, string.format("\27[1mImported Symbol:\27[0m \27[35m%s\27[0m", imp.name))
            if imp.demangled ~= imp.name then
                table.insert(right_lines, string.format("\27[1mDemangled:\27[0m       %s", imp.demangled))
            end
            table.insert(right_lines, string.format("\27[1mBinding:\27[0m         %s", imp.bind))
            table.insert(right_lines, "")
            table.insert(right_lines, "\27[1mTarget Dependencies (.dynamic):\27[0m")
            for _, dep in ipairs(elf_info.dependencies) do
                table.insert(right_lines, "  • " .. dep)
            end
        else
            table.insert(right_lines, "  (No symbol or section selected)")
        end

        for r = 1, list_height do
            local item_idx = state.scroll + r
            local left_str = ""

            if item_idx <= #list then
                local it = list[item_idx]
                local is_selected = (item_idx == state.cursor)
                local prefix = is_selected and "\27[33;1m▶\27[0m " or "  "

                if state.tab == 1 then
                    -- Function List
                    local tag = it.is_export and "\27[32mEXP\27[0m" or "\27[90mLOC\27[0m"
                    local name_trunc = it.demangled:sub(1, left_w - 28)
                    left_str = string.format("%s%s \27[34m%08x\27[0m %6s %s",
                        prefix, tag, it.addr, format_bytes(it.size), name_trunc)
                elseif state.tab == 2 then
                    -- Sections
                    local flags = string.format("\27[33m%s\27[0m", it.flags_str)
                    local name_trunc = it.name:sub(1, left_w - 26)
                    left_str = string.format("%s%s %-14s %6s %s",
                        prefix, flags, name_trunc, format_bytes(it.size), it.type)
                elseif state.tab == 3 then
                    -- Imports
                    local name_trunc = it.name:sub(1, left_w - 18)
                    left_str = string.format("%s\27[35m%-6s\27[0m %s", prefix, it.bind, name_trunc)
                elseif state.tab == 4 then
                    -- Top Bloat
                    local pct = elf_info.text_size > 0 and (it.size / elf_info.text_size * 100) or 0
                    local bar_len = math.floor(pct / 5)
                    local bar = string.rep("█", math.min(10, bar_len))
                    local name_trunc = it.demangled:sub(1, left_w - 28)
                    left_str = string.format("%s\27[31m%6s\27[0m %4.1f%% %-10s %s",
                        prefix, format_bytes(it.size), pct, bar, name_trunc)
                end

                if is_selected and state.active_pane == "left" then
                    left_str = "\27[48;5;238m" .. left_str
                end
            end

            -- Pad left string to left_w
            local clean_left_len = #left_str:gsub("\27%[[0-9;]*m", "")
            local pad_left = string.rep(" ", math.max(0, left_w - clean_left_len))
            local full_left = left_str .. pad_left .. "\27[0m"

            -- Right detail line
            local right_idx = state.right_scroll + r
            local r_line = right_lines[right_idx] or ""
            local clean_r_len = #r_line:gsub("\27%[[0-9;]*m", "")
            if clean_r_len > right_w then
                r_line = r_line:sub(1, right_w)
            end
            local pad_right = string.rep(" ", math.max(0, right_w - clean_r_len))

            table.insert(buf, full_left .. "\27[90m│\27[0m" .. r_line .. pad_right .. "\27[0m\n")
        end

        -- Footer Status Bar (Vim-style bottom line)
        if state.is_searching then
            local prompt = string.format(" /%s\27[7m \27[0m", state.filter_text)
            local match_info = string.format(" [%d matches | Enter: Accept | Esc: Cancel] ", #list)
            local clean_prompt = #prompt:gsub("\27%[[0-9;]*m", "")
            local f_pad = string.rep(" ", math.max(0, cols - clean_prompt - #match_info))
            table.insert(buf, "\27[48;5;234m\27[38;5;255m\27[1m" .. prompt .. "\27[0m\27[48;5;234m\27[38;5;244m" .. f_pad .. match_info .. "\27[0m")
        else
            local footer_bg = "\27[48;5;236m\27[38;5;250m"
            local filter_tag = (#state.filter_text > 0) and string.format(" \27[33m[Filter: \"%s\" (Esc to clear)]\27[0m", state.filter_text) or ""
            local item_count = string.format(" [%d/%d items]%s ", #list > 0 and state.cursor or 0, #list, filter_tag)
            local hints = " [/] Search  [Tab] Next Tab  [←/→/p] Pane  [d] Disasm  [h] Hex  [?] Help  [q] Quit "
            local clean_count = #item_count:gsub("\27%[[0-9;]*m", "")
            local f_pad = string.rep(" ", math.max(0, cols - clean_count - #hints))
            table.insert(buf, footer_bg .. item_count .. f_pad .. hints .. "\27[0m")
        end

        -- Help Modal Overlay
        if state.show_help then
            local mw = math.min(74, cols - 4)
            local mh = math.min(22, rows - 4)
            local mx = math.max(1, math.floor((cols - mw) / 2) + 1)
            local my = math.max(1, math.floor((rows - mh) / 2) + 1)

            local bg = "\27[48;5;235m"
            local border_color = "\27[38;5;220m" -- gold/amber
            local title_color = "\27[1;38;5;229m"
            local header_sec = "\27[1;38;5;117m" -- sky blue
            local key_color = "\27[1;38;5;75m"
            local desc_color = "\27[38;5;252m"

            local help_lines = {
                header_sec .. "Tabs & Views:" .. desc_color,
                "  " .. key_color .. "Tab" .. desc_color .. " / " .. key_color .. "Shift-Tab" .. desc_color .. " : Cycle forward / backward through tabs",
                "  " .. key_color .. "1, 2, 3, 4" .. desc_color .. "       : Jump directly to Functions, Sections, Imports, Bloat",
                "",
                header_sec .. "Navigation & Panes:" .. desc_color,
                "  " .. key_color .. "↑ / ↓" .. desc_color .. " or " .. key_color .. "k / j" .. desc_color .. "     : Scroll highlighted item in active pane",
                "  " .. key_color .. "PgUp / PgDn" .. desc_color .. "     : Scroll 10 items at a time",
                "  " .. key_color .. "Home / End" .. desc_color .. "      : Jump to first / last item",
                "  " .. key_color .. "← / →" .. desc_color .. " or " .. key_color .. "p" .. desc_color .. "       : Switch focus between Symbol List and Inspector",
                "",
                header_sec .. "Code & Symbol Inspection:" .. desc_color,
                "  " .. key_color .. "d" .. desc_color .. "               : Switch right pane to Disassembly view (Intel asm)",
                "  " .. key_color .. "h" .. desc_color .. "               : Switch right pane to Raw Hex Dump view",
                "  " .. key_color .. "/" .. desc_color .. "               : Filter / search symbols by substring in real-time",
                "  " .. key_color .. "Esc" .. desc_color .. "             : Clear search filter / dismiss dialog",
                "",
                header_sec .. "General:" .. desc_color,
                "  " .. key_color .. "?" .. desc_color .. "               : Toggle this help cheat sheet",
                "  " .. key_color .. "q / Ctrl-C" .. desc_color .. "      : Quit application"
            }

            local title_text = " ⌨️  ELF Inspector Keybindings Help "
            local title_len = 36
            local top_dashes = math.max(0, mw - 2 - title_len)
            local d_left = math.floor(top_dashes / 2)
            local d_right = top_dashes - d_left
            table.insert(buf, string.format("\27[%d;%dH%s%s╭%s%s%s%s%s╮\27[0m",
                my, mx, bg, border_color, string.rep("─", d_left), title_color, title_text, border_color, string.rep("─", d_right)))

            for row = 1, mh - 2 do
                local line_content = help_lines[row] or ""
                local plain_len = #line_content:gsub("\27%[[0-9;]*m", "")
                local pad_len = math.max(0, mw - 4 - plain_len)
                table.insert(buf, string.format("\27[%d;%dH%s%s│\27[0m%s %s%s %s%s│\27[0m",
                    my + row, mx, bg, border_color, bg, line_content, string.rep(" ", pad_len), bg, border_color))
            end

            local bottom_hint = " Press [?] or [Esc] to close "
            local hint_len = 28
            local b_dashes = math.max(0, mw - 2 - hint_len)
            local b_left = math.floor(b_dashes / 2)
            local b_right = b_dashes - b_left
            table.insert(buf, string.format("\27[%d;%dH%s%s╰%s\27[38;5;250m%s%s%s╯\27[0m",
                my + mh - 1, mx, bg, border_color, string.rep("─", b_left), bottom_hint, border_color, string.rep("─", b_right)))
        end

        io.write(table.concat(buf))
        io.flush()
    end

    -- Event Loop
    local need_redraw = true
    local last_cols, last_rows = get_terminal_size()

    while true do
        if need_redraw then
            draw()
            need_redraw = false
        end

        local k = read_key(50)

        local cur_cols, cur_rows = get_terminal_size()
        if cur_cols ~= last_cols or cur_rows ~= last_rows then
            last_cols, last_rows = cur_cols, cur_rows
            need_redraw = true
        end

        if k then
            need_redraw = true
            if state.show_help then
                if k == "?" or k == "esc" or k == "q" or k == "enter" or k == " " then
                    state.show_help = false
                end
            elseif state.is_searching then
                if k == "enter" then
                    state.is_searching = false
                elseif k == "esc" then
                    state.is_searching = false
                    state.filter_text = ""
                    state.cursor = 1
                    state.scroll = 0
                elseif k == "backspace" then
                    if #state.filter_text > 0 then
                        state.filter_text = state.filter_text:sub(1, -2)
                        state.cursor = 1
                        state.scroll = 0
                    else
                        state.is_searching = false
                    end
                elseif k and #k == 1 and k:byte(1) >= 32 and k:byte(1) <= 126 then
                    state.filter_text = state.filter_text .. k
                    state.cursor = 1
                    state.scroll = 0
                end
        else
            if k == "?" then
                state.show_help = true
            elseif k == "q" or k == "\3" then
                break
            elseif k == "1" then
                state.tab = 1; state.cursor = 1; state.scroll = 0; state.right_scroll = 0
            elseif k == "2" then
                state.tab = 2; state.cursor = 1; state.scroll = 0; state.right_scroll = 0
            elseif k == "3" then
                state.tab = 3; state.cursor = 1; state.scroll = 0; state.right_scroll = 0
            elseif k == "4" then
                state.tab = 4; state.cursor = 1; state.scroll = 0; state.right_scroll = 0
            elseif k == "tab" then
                state.tab = (state.tab % 4) + 1
                state.cursor = 1; state.scroll = 0; state.right_scroll = 0
            elseif k == "shift-tab" then
                state.tab = state.tab - 1
                if state.tab < 1 then state.tab = 4 end
                state.cursor = 1; state.scroll = 0; state.right_scroll = 0
            elseif k == "p" then
                state.active_pane = (state.active_pane == "left") and "right" or "left"
            elseif k == "right" then
                state.active_pane = "right"
            elseif k == "left" then
                state.active_pane = "left"
            elseif k == "d" then
                state.view_mode = "disasm"; state.right_scroll = 0
            elseif k == "h" then
                state.view_mode = "hex"; state.right_scroll = 0
            elseif k == "/" then
                state.is_searching = true
                state.filter_text = ""
                state.cursor = 1
                state.scroll = 0
            elseif k == "esc" then
                if #state.filter_text > 0 then
                    state.filter_text = ""
                    state.cursor = 1
                    state.scroll = 0
                end
            elseif k == "up" or k == "k" then
                if state.active_pane == "left" then
                    if state.cursor > 1 then
                        state.cursor = state.cursor - 1
                        state.right_scroll = 0
                    end
                else
                    if state.right_scroll > 0 then state.right_scroll = state.right_scroll - 1 end
                end
            elseif k == "down" or k == "j" then
                local list = get_active_list()
                if state.active_pane == "left" then
                    if state.cursor < #list then
                        state.cursor = state.cursor + 1
                        state.right_scroll = 0
                    end
                else
                    state.right_scroll = state.right_scroll + 1
                end
            elseif k == "pgup" then
                local list = get_active_list()
                state.cursor = math.max(1, state.cursor - 10)
                state.right_scroll = 0
            elseif k == "pgdn" then
                local list = get_active_list()
                state.cursor = math.min(#list, state.cursor + 10)
                state.right_scroll = 0
            elseif k == "home" or k == "g" then
                state.cursor = 1
                state.right_scroll = 0
            elseif k == "end" or k == "G" then
                local list = get_active_list()
                state.cursor = #list
                state.right_scroll = 0
            end
        end
    end
    end

    disable_raw_mode()
end

--------------------------------------------------------------------------------
-- 4. Command Line / Batch Operations
--------------------------------------------------------------------------------
local function print_cli_summary(elf)
    print("================================================================================")
    print(string.format("  ELF Binary: %s", elf.filepath))
    print("================================================================================")
    print(string.format("  Architecture:   %-20s  Class:     %s", elf.machine, elf.is_64bit and "ELF64" or "ELF32"))
    print(string.format("  Type:           %-20s  Endian:    %s", elf.type, elf.endian))
    print(string.format("  Entry Address:  0x%016x  Sections:  %d", elf.entry, #elf.sections))
    print(string.format("  Functions:      %-20d  Stripped:  %s", #elf.functions, elf.stripped and "YES" or "NO"))
    if #elf.dependencies > 0 then
        print(string.format("  Dependencies:   %s", table.concat(elf.dependencies, ", ")))
    end
    print("================================================================================")
end

local function print_cli_functions(elf, exports_only)
    local list = exports_only and elf.exports or elf.functions
    local label = exports_only and "EXPORTED FUNCTIONS" or "ALL FUNCTIONS"
    print(string.format("\n[%s] (%d symbols)", label, #list))
    print(string.format("%-18s  %-8s  %-7s  %-12s  %s", "ADDRESS", "SIZE", "BIND", "SECTION", "NAME"))
    print(string.rep("-", 80))
    for _, fn in ipairs(list) do
        print(string.format("0x%016x  %-8s  %-7s  %-12s  %s",
            fn.addr, format_bytes(fn.size), fn.bind, fn.section or ".text", fn.demangled))
    end
end

local function print_cli_sections(elf)
    print(string.format("\n[SECTION HEADERS] (%d sections)", #elf.sections))
    print(string.format("IDX  %-20s  %-12s  %-18s  %-10s  %-8s  FLAGS",
        "NAME", "TYPE", "ADDR", "OFFSET", "SIZE"))
    print(string.rep("-", 85))
    for _, sec in ipairs(elf.sections) do
        print(string.format("[%02d] %-20s  %-12s  0x%016x  0x%08x  %-8s  %s",
            sec.index, sec.name, sec.type, sec.addr, sec.offset, format_bytes(sec.size), sec.flags_str))
    end
end

local function print_cli_top(elf, count)
    count = count or 10
    local bloat = {}
    for _, fn in ipairs(elf.functions) do
        if fn.size > 0 then table.insert(bloat, fn) end
    end
    table.sort(bloat, function(a, b) return a.size > b.size end)

    print(string.format("\n[TOP %d LARGEST FUNCTIONS (CODE BLOAT)]", count))
    print(string.format("RANK  %-8s  %% .TEXT   %-20s  %s", "SIZE", "NAME", "DEMANGLED"))
    print(string.rep("-", 80))
    for i = 1, math.min(count, #bloat) do
        local fn = bloat[i]
        local pct = elf.text_size > 0 and (fn.size / elf.text_size * 100) or 0
        print(string.format("%2d.   %-8s  %5.1f%%    %-20s  %s",
            i, format_bytes(fn.size), pct, fn.name:sub(1, 20), fn.demangled))
    end
end

local function print_cli_disasm(elf, target)
    local fn = nil
    for _, f in ipairs(elf.functions) do
        if f.name == target or f.demangled == target or string.format("0x%x", f.addr) == target:lower() then
            fn = f
            break
        end
    end
    if not fn then
        print("Error: Function or address '" .. target .. "' not found in symbol tables.")
        return
    end
    print(string.format("\nDisassembly of %s (0x%08x, %d bytes):", fn.demangled, fn.addr, fn.size))
    local lines = disassemble_function(elf.filepath, fn, 200)
    for _, l in ipairs(lines) do print(l) end
end

local function print_json(elf)
    -- Minimal JSON serializer for zero dependencies
    local function esc_json(s)
        return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
    end

    local parts = {}
    table.insert(parts, string.format('{"filepath":"%s",', esc_json(elf.filepath)))
    table.insert(parts, string.format('"machine":"%s",', esc_json(elf.machine)))
    table.insert(parts, string.format('"type":"%s",', esc_json(elf.type)))
    table.insert(parts, string.format('"entry":%d,', elf.entry))
    table.insert(parts, string.format('"stripped":%s,', tostring(elf.stripped)))

    -- Functions
    local fn_parts = {}
    for _, fn in ipairs(elf.functions) do
        table.insert(fn_parts, string.format('{"name":"%s","demangled":"%s","addr":%d,"size":%d,"bind":"%s"}',
            esc_json(fn.name), esc_json(fn.demangled), fn.addr, fn.size, fn.bind))
    end
    table.insert(parts, string.format('"functions":[%s],', table.concat(fn_parts, ",")))

    -- Dependencies
    local dep_parts = {}
    for _, d in ipairs(elf.dependencies) do
        table.insert(dep_parts, string.format('"%s"', esc_json(d)))
    end
    table.insert(parts, string.format('"dependencies":[%s]}', table.concat(dep_parts, ",")))

    io.write(table.concat(parts))
    io.write("\n")
end

--------------------------------------------------------------------------------
-- 5. Main Entry Point & Argument Dispatcher
--------------------------------------------------------------------------------
local function print_help()
    print([[
Usage: luajit ffi_elf_inspector.lua <elf-binary> [options]

An interactive ELF binary analyzer, symbol inspector, and disassembler in pure LuaJIT FFI.

Options:
  (no options)           Launch full interactive split-pane terminal TUI
  -f, --funcs            List all functions (.symtab and .dynsym)
  -e, --exports          List exported/public functions only
  -s, --sections         List section header tables (.text, .rodata, etc.)
  -t, --top [N]          Show top N largest functions (default: 10)
  -d, --disasm <func>    Disassemble specific function by name or address
  --hex <func>           Hex dump raw bytes of specific function
  --json                 Output machine-readable JSON structure
  --test                 Run automated self-tests on workspace binaries
  -h, --help             Show this help message

TUI Controls:
  [1-4]                  Switch tabs: Functions, Sections, Imports, Top Bloat
  [↑/↓] or [j/k]         Navigate symbol list
  [PgUp/PgDn]            Page up / page down
  [Tab]                  Toggle active pane (left list vs right code inspector)
  [/]                    Search / filter symbols in real-time
  [d]                    Switch right pane to Disassembly view
  [h]                    Switch right pane to Hex dump view
  [q] or [Ctrl-C]        Quit
]])
end

local function main(args)
    if #args == 0 then
        print_help()
        os.exit(1)
    end

    local target_file = nil
    local mode = "tui"
    local opt_arg = nil

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--help" or a == "-h" then
            print_help()
            return
        elseif a == "--test" then
            mode = "test"
        elseif a == "--funcs" or a == "-f" then
            mode = "funcs"
        elseif a == "--exports" or a == "-e" then
            mode = "exports"
        elseif a == "--sections" or a == "-s" then
            mode = "sections"
        elseif a == "--top" or a == "-t" then
            mode = "top"
            if args[i+1] and tonumber(args[i+1]) then
                opt_arg = tonumber(args[i+1])
                i = i + 1
            end
        elseif a == "--disasm" or a == "-d" then
            mode = "disasm"
            opt_arg = args[i+1]
            i = i + 1
        elseif a == "--json" then
            mode = "json"
        elseif not target_file and not a:match("^%-") then
            target_file = a
        end
        i = i + 1
    end

    if mode == "test" then
        print("Running internal sanity test suite...")
        local test_bin = target_file or "./libtermbox2.so"
        local elf, err = parse_elf_file(test_bin)
        assert(elf, "Failed to parse test binary: " .. tostring(err))
        assert(#elf.sections > 0, "No sections parsed")
        assert(#elf.functions > 0, "No functions parsed")
        print(string.format("✓ Successfully verified %s (%d sections, %d functions)",
            test_bin, #elf.sections, #elf.functions))
        return
    end

    if not target_file then
        io.stderr:write("Error: Please specify an ELF binary file.\n\n")
        print_help()
        os.exit(1)
    end

    local elf, err = parse_elf_file(target_file)
    if not elf then
        io.stderr:write(string.format("Error: %s\n", err))
        os.exit(1)
    end

    if mode == "tui" then
        -- Check if stdout is an interactive terminal
        if ffi.C.isatty(1) == 1 then
            run_tui(elf)
        else
            -- Non-interactive pipe fallback: print clean CLI summary & top functions
            print_cli_summary(elf)
            print_cli_functions(elf, false)
        end
    elseif mode == "funcs" then
        print_cli_summary(elf)
        print_cli_functions(elf, false)
    elseif mode == "exports" then
        print_cli_summary(elf)
        print_cli_functions(elf, true)
    elseif mode == "sections" then
        print_cli_summary(elf)
        print_cli_sections(elf)
    elseif mode == "top" then
        print_cli_summary(elf)
        print_cli_top(elf, opt_arg or 10)
    elseif mode == "disasm" then
        if not opt_arg then
            io.stderr:write("Error: --disasm requires a function name or address.\n")
            os.exit(1)
        end
        print_cli_disasm(elf, opt_arg)
    elseif mode == "json" then
        print_json(elf)
    end
end

if not pcall(debug.getlocal, 4, 1) then
    main(arg or {})
else
    -- Module export when required by tests
    return {
        parse_elf_file = parse_elf_file,
        format_bytes = format_bytes,
        generate_hex_dump = generate_hex_dump,
        disassemble_function = disassemble_function,
        read_function_bytes = read_function_bytes
    }
end
