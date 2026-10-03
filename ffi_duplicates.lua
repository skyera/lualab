#!/usr/bin/env luajit
-- Read-only duplicate finder. Windows / Linux 64-bit; bounded read buffers.

local ffi, bit = require('ffi'), require('bit')

assert(
    ffi.os == 'Windows' or (ffi.os == 'Linux' and ffi.abi('64bit')),
    'ffi_duplicates requires Windows or 64-bit Linux'
)
ffi.cdef([[int memcmp(const void *a, const void *b, size_t n);]])

local function windows_backend(native, shell)
    ffi.cdef([[
        typedef struct {
            uint32_t low, high;
        } DupFileTime;
        typedef struct {
            uint32_t attributes;
            DupFileTime creation, access, write;
            uint32_t volume, size_high, size_low, links, index_high, index_low;
        } DupFileInfo;
        typedef struct {
            int64_t creation, access, write, change;
            uint32_t attributes;
        } DupBasicInfo;
        typedef struct {
            uint64_t volume;
            uint8_t id[16];
        } DupIdInfo;
        typedef struct {
            uint32_t attributes;
            DupFileTime creation, access, write;
            uint32_t size_high, size_low, reserved0, reserved1;
            uint16_t name[260], alternate[14];
        } DupFindData;
        void *__stdcall CreateFileW(const uint16_t *, uint32_t, uint32_t, void *, uint32_t,
                                    uint32_t, void *);
        int __stdcall GetFileInformationByHandle(void *, DupFileInfo *);
        int __stdcall GetFileInformationByHandleEx(void *, int, void *, uint32_t);
        uint32_t __stdcall GetFileType(void *);
        int __stdcall ReadFile(void *, void *, uint32_t, uint32_t *, void *);
        int __stdcall WriteFile(void *, const void *, uint32_t, uint32_t *, void *);
        int __stdcall CloseHandle(void *);
        void *__stdcall FindFirstFileW(const uint16_t *, DupFindData *);
        int __stdcall FindNextFileW(void *, DupFindData *);
        int __stdcall FindClose(void *);
        uint32_t __stdcall GetLastError(void);
        uint32_t __stdcall GetFullPathNameW(const uint16_t *, uint32_t, uint16_t *, uint16_t **);
        int __stdcall MultiByteToWideChar(unsigned int, uint32_t, const char *, int, uint16_t *,
                                          int);
        int __stdcall WideCharToMultiByte(unsigned int, uint32_t, const uint16_t *, int, char *,
                                          int, const char *, int *);
        const uint16_t *__stdcall GetCommandLineW(void);
        uint16_t **__stdcall CommandLineToArgvW(const uint16_t *, int *);
        void *__stdcall LocalFree(void *);
        uint32_t __stdcall GetConsoleOutputCP(void);
        int __stdcall SetConsoleOutputCP(uint32_t);
    ]])
    local invalid = ffi.cast('void*', -1)
    native = native or ffi.load('kernel32')
    local M = {}

    local function err()
        return 'Windows error ' .. tonumber(native.GetLastError())
    end

    function M.wide(s)
        if s == '' or s:find('\0', 1, true) then
            return nil, 'Empty path or embedded NUL'
        end
        local n = native.MultiByteToWideChar(65001, 8, s, #s, nil, 0)
        if n == 0 then
            return nil, 'Invalid UTF-8 path'
        end
        local out = ffi.new('uint16_t[?]', n + 1)
        if native.MultiByteToWideChar(65001, 8, s, #s, out, n) ~= n then
            return nil, err()
        end
        return out
    end

    function M.from_wide(s)
        local n = native.WideCharToMultiByte(65001, 0, s, -1, nil, 0, nil, nil)
        if n == 0 then
            return nil, err()
        end
        local out = ffi.new('char[?]', n)
        if native.WideCharToMultiByte(65001, 0, s, -1, out, n, nil, nil) ~= n then
            return nil, err()
        end
        return ffi.string(out, n - 1)
    end

    function M.path(path)
        path = path:gsub('/', '\\')
        -- Only filesystem paths: reject device namespaces (including named pipes).
        if path:sub(1, 4) == '\\\\?\\' then
            if not path:match('^\\\\%?\\%a:\\') and path:sub(1, 8):upper() ~= '\\\\?\\UNC\\' then
                return nil, 'Unsupported Windows device path'
            end
            return M.wide(path)
        end
        if path:sub(1, 4) == '\\\\.\\' then
            return nil, 'Unsupported Windows device path'
        end
        local input, e = M.wide(path)
        if not input then
            return nil, e
        end
        local n = native.GetFullPathNameW(input, 0, nil, nil)
        if n == 0 then
            return nil, err()
        end
        local out = ffi.new('uint16_t[?]', n + 1)
        local written = native.GetFullPathNameW(input, n + 1, out, nil)
        if written == 0 or written > n then
            return nil, 'Cannot resolve Windows path'
        end
        local full
        full, e = M.from_wide(out)
        if not full then
            return nil, e
        end
        if full:sub(1, 2) == '\\\\' then
            full = '\\\\?\\UNC\\' .. full:sub(3)
        else
            full = '\\\\?\\' .. full
        end
        return M.wide(full)
    end

    local function open_path(path, access)
        local name, e = M.path(path)
        if not name then
            return nil, e
        end
        -- OPEN_EXISTING, shared read/write/delete; inspect reparse points themselves.
        local h = native.CreateFileW(name, access, 7, nil, 3, 0x02200000, nil)
        if h == invalid or h == nil then
            return nil, err()
        end
        return h
    end

    function M.close(h)
        native.CloseHandle(h)
    end

    function M.open(path)
        return open_path(path, 0x80000000)
    end

    function M.write_new(path, text)
        local name, e = M.path(path)
        if not name then
            return nil, e
        end
        local h = native.CreateFileW(name, 0x40000000, 0, nil, 1, 128, nil)
        if h == invalid or h == nil then
            return nil, err()
        end
        local offset, count = 1, ffi.new('uint32_t[1]')
        while offset <= #text do
            local part = text:sub(offset, offset + 65535)
            if native.WriteFile(h, part, #part, count, nil) == 0 then
                e = err()
                break
            end
            if count[0] == 0 then
                e = 'Export write made no progress'
                break
            end
            offset = offset + tonumber(count[0])
        end
        if native.CloseHandle(h) == 0 and not e then
            e = err()
        end
        if e then
            return nil, e
        end
        return true
    end

    function M.metadata(path, handle)
        local h, e = handle
        if not h then
            h, e = open_path(path, 0x80)
            if not h then
                return nil, e
            end
        end

        local function finish(value, message)
            if not handle then
                M.close(h)
            end
            return value, message
        end
        if native.GetFileType(h) ~= 1 then
            return finish(nil, 'Not a disk file')
        end
        local info = ffi.new('DupFileInfo[1]')
        if native.GetFileInformationByHandle(h, info) == 0 then
            return finish(nil, err())
        end
        local attr = info[0].attributes
        if bit.band(attr, 0x400) ~= 0 then
            return finish({ kind = 0xa000 })
        end
        if info[0].size_high > 0x1fffff then
            return finish(nil, 'file size exceeds exact numeric range')
        end
        local basic, identity = ffi.new('DupBasicInfo[1]'), ffi.new('DupIdInfo[1]')
        if
            native.GetFileInformationByHandleEx(h, 0, basic, ffi.sizeof(basic)) == 0
            or native.GetFileInformationByHandleEx(h, 18, identity, ffi.sizeof(identity)) == 0
        then
            return finish(nil, err())
        end
        local hex = {}
        for i = 0, 15 do
            hex[#hex + 1] = string.format('%02x', identity[0].id[i])
        end
        local id = tostring(identity[0].volume) .. ':' .. table.concat(hex)
        local size = tonumber(info[0].size_high) * 4294967296 + tonumber(info[0].size_low)
        local signature = id
            .. ':'
            .. string.format('%.0f', size)
            .. ':'
            .. tostring(basic[0].write)
            .. ':'
            .. tostring(basic[0].change)
        return finish({
            id = id,
            signature = signature,
            size = size,
            kind = bit.band(attr, 16) ~= 0 and 0x4000 or 0x8000,
        })
    end

    function M.read(h, buffer, size)
        local count = ffi.new('uint32_t[1]')
        if native.ReadFile(h, buffer, size, count, nil) == 0 then
            return nil, err()
        end
        return tonumber(count[0])
    end

    function M.join(path, name)
        -- Preserve drive-relative C:foo semantics, and drive/UNC roots.
        if path:match('^%a:$') then
            return path .. name
        end
        return path:gsub('[/\\]+$', '') .. '\\' .. name
    end

    function M.list(path, visit)
        local pattern, e = M.path(M.join(path, '*'))
        if not pattern then
            return nil, e
        end
        local data = ffi.new('DupFindData[1]')
        local h = native.FindFirstFileW(pattern, data)
        if h == invalid or h == nil then
            if native.GetLastError() == 2 then
                return true
            end
            return nil, err()
        end
        local message
        while true do
            local name
            name, e = M.from_wide(data[0].name)
            if not name then
                message = e
                break
            end
            if name ~= '.' and name ~= '..' then
                if visit(name) == false then
                    break
                end
            end
            if native.FindNextFileW(h, data) == 0 then
                if native.GetLastError() ~= 18 then
                    message = err()
                end
                break
            end
        end
        native.FindClose(h)
        if message then
            return nil, message
        end
        return true
    end

    function M.arguments(args)
        shell = shell or ffi.load('shell32')
        local count = ffi.new('int[1]')
        local argv = shell.CommandLineToArgvW(native.GetCommandLineW(), count)
        if argv == nil then
            return nil, err()
        end
        local result, message = {}, nil
        -- LuaJIT has already parsed interpreter/script arguments; replace only its
        -- trailing script arguments, avoiding the CRT's lossy ANSI conversion.
        if count[0] < #args then
            message = 'Cannot decode Windows arguments'
        else
            for i = tonumber(count[0]) - #args, tonumber(count[0]) - 1 do
                local text, e = M.from_wide(argv[i])
                if not text then
                    message = e
                    break
                end
                result[#result + 1] = text
            end
        end
        native.LocalFree(argv)
        if message then
            return nil, message
        end
        return result
    end

    function M.console_utf8()
        local previous = native.GetConsoleOutputCP()
        if previous ~= 0 and native.SetConsoleOutputCP(65001) ~= 0 then
            return function()
                native.SetConsoleOutputCP(previous)
            end
        end
    end
    return M
end

local function linux_backend()
    assert(ffi.os == 'Linux' and ffi.abi('64bit'), 'ffi_duplicates requires 64-bit Linux')
    ffi.cdef([[
        typedef struct {
            int64_t sec;
            uint32_t nsec;
            int32_t reserved;
        } dup_timestamp;
        typedef struct {
            uint32_t mask, blksize;
            uint64_t attributes;
            uint32_t nlink, uid, gid;
            uint16_t mode, spare0;
            uint64_t ino, size, blocks, attributes_mask;
            dup_timestamp atime, btime, ctime, mtime;
            uint32_t rdev_major, rdev_minor, dev_major, dev_minor;
            uint64_t spare[14];
        } dup_stat;
        typedef struct {
            uint64_t ino;
            int64_t off;
            unsigned short reclen;
            unsigned char type;
            char name[256];
        } dup_dirent;
        void *opendir(const char *name);
        dup_dirent *readdir(void *dir);
        int closedir(void *dir);
        int statx(int fd, const char *path, int flags, unsigned int mask, dup_stat *out);
        int open(const char *path, int flags, ...);
        long read(int fd, void *buf, unsigned long count);
        long write(int fd, const void *buf, unsigned long count);
        int close(int fd);
        char *strerror(int err);
    ]])
    local C, M = ffi.C, {}

    local function err()
        return ffi.string(C.strerror(ffi.errno()))
    end

    function M.metadata(path, fd)
        local s = ffi.new('dup_stat')
        if C.statx(fd or -100, fd and '' or path, fd and 4096 or 256, 0x7ff, s) ~= 0 then
            return nil, err()
        end
        if bit.band(s.mask, 0x3c3) ~= 0x3c3 then
            return nil, 'incomplete filesystem metadata'
        end
        if s.size > 9007199254740991ULL then
            return nil, 'file size exceeds exact numeric range'
        end
        local id = s.dev_major .. ':' .. s.dev_minor .. ':' .. tostring(s.ino)
        local signature = id
            .. ':'
            .. tostring(s.size)
            .. ':'
            .. tostring(s.mtime.sec)
            .. ':'
            .. s.mtime.nsec
            .. ':'
            .. tostring(s.ctime.sec)
            .. ':'
            .. s.ctime.nsec
        return {
            id = id,
            signature = signature,
            size = tonumber(s.size),
            kind = bit.band(s.mode, 0xf000),
        }
    end

    function M.open(path)
        local fd = C.open(path, 0x20000 + 0x800 + 0x80000)
        if fd < 0 then
            return nil, err()
        end
        return fd
    end

    function M.write_new(path, text)
        local fd = C.open(path, 0x80000 + 0x20000 + 0xc1, ffi.cast('unsigned int', 420))
        if fd < 0 then
            return nil, err()
        end
        local offset, e = 1, nil
        while offset <= #text do
            local part = text:sub(offset, offset + 65535)
            local n = tonumber(C.write(fd, part, #part))
            if n < 0 then
                if ffi.errno() ~= 4 then
                    e = err()
                    break
                end
            elseif n == 0 then
                e = 'Export write made no progress'
                break
            else
                offset = offset + n
            end
        end
        if C.close(fd) ~= 0 and not e then
            e = err()
        end
        if e then
            return nil, e
        end
        return true
    end

    function M.read(fd, buf, size)
        while true do
            local n = tonumber(C.read(fd, buf, size))
            if n >= 0 then
                return n
            end
            if ffi.errno() ~= 4 then
                return nil, err()
            end
        end
    end

    function M.close(fd)
        C.close(fd)
    end

    function M.join(path, name)
        return path:gsub('/+$', '') .. '/' .. name
    end

    function M.list(path, visit)
        local d = C.opendir(path)
        if d == nil then
            return nil, err()
        end
        local message
        while true do
            ffi.errno(0)
            local entry = C.readdir(d)
            if entry == nil then
                if ffi.errno() ~= 0 then
                    message = err()
                end
                break
            end
            local name = ffi.string(entry.name)
            if name ~= '.' and name ~= '..' then
                if visit(name) == false then
                    break
                end
            end
        end
        C.closedir(d)
        if message then
            return nil, message
        end
        return true
    end
    return M
end

local backend = ffi.os == 'Windows' and windows_backend() or linux_backend()

-- The TUI model and frame generators are independent of terminal I/O.
local TUI = {}
TUI.help_lines = {
    'Browsing',
    '  Up/Down or j/k  Move in the active pane.',
    '  PgUp/PgDn       Move one page; Home/End jump to first/last.',
    '  Tab             Switch groups/files; narrow screens show one pane.',
    '  Enter           View full paths and sizes for the current group.',
    '  /               Filter groups by literal text in any file path.',
    '  Space           Mark/unmark the current group for export.',
    '  e               Export marked groups, or the current group if none marked.',
    '  !               View scan errors.',
    '  ?               Open help; press ? again to return.',
    '  q or Esc        Quit from the browsing view.',
    '',
    'Filter and export prompts',
    '  Type text       Spaces and Unicode characters are supported.',
    '  Backspace       Remove the last character.',
    '  Enter           Keep the filter, or write the JSON export.',
    '  Esc             Cancel; a filter returns to its previous value.',
    '  Clear filter    Press /, erase its text, then Enter.',
    '',
    'Details, errors, and help',
    '  Up/Down         Scroll one line.',
    '  PgUp/PgDn       Scroll one page; Home/End jump to top/bottom.',
    '  Enter/Esc or q  Return to the previous view.',
    '  Ctrl-C          Exit from any view or prompt (status 130).',
    '',
    'Scan and export behavior',
    '  During scanning, q or Esc cancels; Ctrl-C exits with status 130.',
    '  Groups contain byte-identical files and are sorted by redundant bytes.',
    '  Marked groups remain marked when hidden by a filter.',
    '  Export writes JSON to a NEW filename; existing files are preserved.',
    '  A failed export may leave a partial file. Scanned files are read-only.',
    '  Redundant bytes describe logical content, not guaranteed disk savings.',
}
local CLI_HELP = table.concat({
    'Duplicate Finder - find byte-identical files without modifying them.',
    '',
    'Usage: luajit ffi_duplicates.lua [OPTIONS] [--] [PATH ...]',
    'Scan files or directories recursively. With no PATH, scan the current directory.',
    '',
    'Options',
    '  --tui              Browse groups in an interactive terminal or Windows console.',
    '  --json             Write machine-readable results to stdout; errors go to stderr.',
    '  --min-size=BYTES   Include files at least this many bytes (default: 0).',
    '  -h, --help         Show this help and exit.',
    '  --                 Treat all following arguments as paths, even if starting with -.',
    '  --tui and --json cannot be combined.',
    '',
    'Examples',
    '  luajit ffi_duplicates.lua                         # Scan the current directory',
    '  luajit ffi_duplicates.lua ./photos ./backup       # Scan multiple roots',
    '  luajit ffi_duplicates.lua --tui ./photos          # Browse duplicate groups',
    '  luajit ffi_duplicates.lua --min-size=1048576 .    # Files of at least 1 MiB',
    '  luajit ffi_duplicates.lua --min-size=1 .          # Exclude empty files',
    '  luajit ffi_duplicates.lua --json . > duplicates.json',
    '  luajit ffi_duplicates.lua -- -photos              # A path starting with -',
    '  luajit ffi_duplicates.lua --tui "C:\\Users\\Alice\\Downloads"',
    '',
    'Scanning and results',
    '  Hidden and empty files are included unless excluded by --min-size.',
    '  Symlinks, Windows reparse points, and special files are skipped.',
    '  Repeated roots and hard links are counted once by native file identity.',
    '  Matches are confirmed byte-for-byte. CLI groups are sorted by file size.',
    '  Scans are not snapshots; detected file changes are reported as errors.',
    '  Redundant bytes describe logical content, not guaranteed disk savings.',
    '  Requires Windows 8+ with file-ID support, or 64-bit Linux with statx.',
    '  --tui requires interactive input AND output; use CLI/JSON for pipelines.',
    '',
    'Exit status',
    '  0  Complete CLI scan (including no matches), or normal TUI exit/cancellation.',
    '  1  CLI scan errors or a TUI runtime failure.',
    '  2  Invalid arguments or an unavailable interactive terminal.',
    '  130  Ctrl-C in the TUI.',
    '',
    'TUI keys - press ? inside the interface for scrollable help',
}, '\n') .. '\n' .. table.concat(TUI.help_lines, '\n') .. '\n'
local function char_at(text, index)
    local b = text:byte(index)
    if not b then
        return nil
    end
    local n = b < 128 and 1
        or b >= 194 and b <= 223 and 2
        or b >= 224 and b <= 239 and 3
        or b >= 240 and b <= 244 and 4
        or 1
    if index + n - 1 > #text then
        return nil
    end
    local cp = n == 1 and b or b % (2 ^ (7 - n))
    for j = 1, n - 1 do
        local c = text:byte(index + j)
        if c < 128 or c > 191 then
            return '?', 1, 63
        end
        cp = cp * 64 + c - 128
    end
    if
        (n == 1 and b >= 128)
        or (
            n > 1
            and (
                cp < ({ [2] = 128, [3] = 2048, [4] = 65536 })[n]
                or cp > 0x10ffff
                or (cp >= 0xd800 and cp <= 0xdfff)
            )
        )
    then
        return '?', 1, 63
    end
    return text:sub(index, index + n - 1), n, cp
end
local function cell_width(cp)
    if (cp >= 0x300 and cp <= 0x36f) or (cp >= 0xfe00 and cp <= 0xfe0f) then
        return 0
    end
    if
        cp >= 0x1100
        and (
            cp <= 0x115f
            or (cp >= 0x2e80 and cp <= 0xa4cf)
            or (cp >= 0xac00 and cp <= 0xd7a3)
            or (cp >= 0xf900 and cp <= 0xfaff)
            or (cp >= 0xfe10 and cp <= 0xff60)
            or (cp >= 0xffe0 and cp <= 0xffe6)
            or cp >= 0x1f300
        )
    then
        return 2
    end
    return 1
end
function TUI.fit(text, width)
    local out, used, i = {}, 0, 1
    while i <= #text do
        local ch, n, cp = char_at(text, i)
        if not ch then
            ch, n, cp = '?', 1, 63
        end
        if cp < 32 or (cp >= 127 and cp < 160) then
            ch, cp = ' ', 32
        end
        local cells = cell_width(cp)
        if used + cells > width then
            break
        end
        out[#out + 1], used, i = ch, used + cells, i + n
    end
    return table.concat(out) .. string.rep(' ', math.max(0, width - used))
end
local function pop_utf8(text)
    local i = #text
    while i > 0 and text:byte(i) >= 128 and text:byte(i) < 192 do
        i = i - 1
    end
    return text:sub(1, math.max(0, i - 1))
end
local function wrap(text, width)
    local lines, line, used, i = {}, {}, 0, 1
    width = math.max(1, width)
    while i <= #text do
        local ch, n, cp = char_at(text, i)
        if not ch then
            ch, n, cp = '?', 1, 63
        end
        if cp < 32 or (cp >= 127 and cp < 160) then
            ch, cp = ' ', 32
        end
        local cells = cell_width(cp)
        if cells > width then
            ch, cells = '?', 1
        end
        if used + cells > width then
            lines[#lines + 1], line, used = table.concat(line), {}, 0
        end
        line[#line + 1], used, i = ch, used + cells, i + n
    end
    lines[#lines + 1] = table.concat(line)
    return lines
end
local function tail(text, width)
    local lines = wrap(text, width)
    return lines[#lines]
end
local function human(bytes)
    local units, index = { 'B', 'KiB', 'MiB', 'GiB', 'TiB' }, 1
    while bytes >= 1024 and index < #units do
        bytes, index = bytes / 1024, index + 1
    end
    return string.format(index == 1 and '%.0f %s' or '%.1f %s', bytes, units[index])
end
function TUI.decoder()
    local pending = ''
    return function(bytes, flush)
        pending = pending .. (bytes or '')
        local keys = {}
        while #pending > 0 do
            if pending:sub(1, 1) == '\27' then
                if
                    not flush
                    and (pending == '\27' or pending:match('^\27%[[0-9;]*$') or pending == '\27O')
                then
                    break
                end
                local sequence = pending:match('^\27%[[0-9;]*[A-Za-z~]')
                    or pending:match('^\27O[A-Za-z]')
                if sequence then
                    local key = ({
                        ['\27[A'] = 'UP',
                        ['\27[B'] = 'DOWN',
                        ['\27[C'] = 'RIGHT',
                        ['\27[D'] = 'LEFT',
                        ['\27[5~'] = 'PAGE_UP',
                        ['\27[6~'] = 'PAGE_DOWN',
                        ['\27[H'] = 'HOME',
                        ['\27[F'] = 'END',
                        ['\27OH'] = 'HOME',
                        ['\27OF'] = 'END',
                        ['\27[1~'] = 'HOME',
                        ['\27[4~'] = 'END',
                    })[sequence]
                    if key then
                        keys[#keys + 1] = key
                    end
                    pending = pending:sub(#sequence + 1)
                else
                    keys[#keys + 1] = 'ESC'
                    pending = pending:sub(2)
                end
            else
                local ch, n = char_at(pending, 1)
                if not ch then
                    if not flush then
                        break
                    end
                    ch, n = '?', 1
                end
                keys[#keys + 1] = ({
                    [' '] = 'SPACE',
                    ['\t'] = 'TAB',
                    ['\127'] = 'BACKSPACE',
                    ['\8'] = 'BACKSPACE',
                    ['\r'] = 'ENTER',
                    ['\n'] = 'ENTER',
                    ['\3'] = 'CTRL_C',
                })[ch] or ch
                pending = pending:sub(n + 1)
            end
        end
        return keys
    end
end
local Model = {}
Model.__index = Model
function TUI.model(result)
    local model = setmetatable({
        result = result,
        groups = {},
        visible = {},
        marked = {},
        group = 1,
        file = 1,
        group_scroll = 0,
        file_scroll = 0,
        pane = 'groups',
        query = '',
        view = 'browse',
        detail_scroll = 0,
        status = 'Ready',
        input = '',
        cols = 80,
        rows = 24,
    }, Model)
    for _, group in ipairs(result.groups) do
        model.groups[#model.groups + 1] = group
    end
    table.sort(model.groups, function(a, b)
        local av, bv = a.size * (#a.paths - 1), b.size * (#b.paths - 1)
        return av == bv and a.paths[1] < b.paths[1] or av > bv
    end)
    model:filter()
    return model
end
function Model:selected()
    return self.visible[self.group]
end
function Model:filter()
    self.visible = {}
    local query = self.query:lower()
    for _, group in ipairs(self.groups) do
        for _, path in ipairs(group.paths) do
            if path:lower():find(query, 1, true) then
                self.visible[#self.visible + 1] = group
                break
            end
        end
    end
    self.group, self.file, self.group_scroll, self.file_scroll = 1, 1, 0, 0
    self.filter_pending = false
end
function Model:clamp(cols, rows)
    self.cols, self.rows = cols, rows
    local height = math.max(1, rows - 4)
    local function clamp(selected, scroll, count)
        selected = count == 0 and 0 or math.max(1, math.min(count, selected))
        scroll = math.max(0, math.min(scroll, math.max(0, count - height)))
        if selected > 0 then
            scroll = math.max(0, math.min(selected - 1, math.max(scroll, selected - height)))
        end
        return selected, scroll
    end
    self.group, self.group_scroll = clamp(self.group, self.group_scroll, #self.visible)
    local group = self:selected()
    self.file, self.file_scroll = clamp(self.file, self.file_scroll, group and #group.paths or 0)
    if self.view ~= 'browse' then
        self.detail_scroll = math.min(
            self.detail_scroll,
            math.max(0, #TUI.detail_lines(self, math.max(1, cols - 1)) - height)
        )
    end
end
function Model:export_result()
    local result = {
        groups = {},
        errors = self.result.errors,
        files = self.result.files,
        redundant_bytes = 0,
        skipped_links = self.result.skipped_links,
    }
    for _, group in ipairs(self.groups) do
        if self.marked[group] then
            result.groups[#result.groups + 1] = group
        end
    end
    if #result.groups == 0 and self:selected() then
        result.groups[1] = self:selected()
    end
    for _, group in ipairs(result.groups) do
        result.redundant_bytes = result.redundant_bytes + group.size * (#group.paths - 1)
    end
    return result
end
function Model:key(key)
    if key == 'CTRL_C' or key == 'EOF' then
        return false
    end
    if self.prompt then
        if key == 'ESC' then
            if self.prompt == 'filter' then
                self.query = self.before_query
                self.filter_pending = true
            end
            self.prompt = nil
        elseif key == 'ENTER' then
            if self.prompt == 'export' then
                if self.input == '' then
                    self.status = 'Enter a new JSON filename'
                    return true
                end
                local effect = { path = self.input, result = self:export_result() }
                self.prompt = nil
                return true, effect
            end
            self.prompt = nil
        elseif key == 'BACKSPACE' then
            self.input = pop_utf8(self.input)
        else
            local text = key == 'SPACE' and ' ' or key
            local _, n = char_at(text, 1)
            if n == #text and not text:find('[%z\1-\31\127]') then
                self.input = self.input .. text
            end
        end
        if self.prompt == 'filter' then
            self.query = self.input
            self.filter_pending = true
        end
        return true
    end
    if key == '?' then
        if self.view == 'help' then
            self.view, self.detail_scroll = self.help_return_view, self.help_return_scroll
        else
            self.help_return_view, self.help_return_scroll = self.view, self.detail_scroll
            self.view, self.detail_scroll = 'help', 0
        end
        self:clamp(self.cols, self.rows)
        return true
    end
    if self.view ~= 'browse' then
        if key == 'ESC' or key == 'ENTER' or key == 'q' then
            if self.view == 'help' then
                self.view, self.detail_scroll = self.help_return_view, self.help_return_scroll
            else
                self.view, self.detail_scroll = 'browse', 0
            end
        else
            local delta = ({
                UP = -1,
                DOWN = 1,
                PAGE_UP = -math.max(1, self.rows - 4),
                PAGE_DOWN = math.max(1, self.rows - 4),
            })[key]
            if key == 'HOME' then
                self.detail_scroll = 0
            elseif key == 'END' then
                self.detail_scroll = 1000000000
            elseif delta then
                self.detail_scroll = math.max(0, self.detail_scroll + delta)
            end
        end
        self:clamp(self.cols, self.rows)
        return true
    end
    if key == 'q' or key == 'ESC' then
        return false
    elseif key == 'TAB' then
        self.pane = self.pane == 'groups' and 'files' or 'groups'
    elseif key == '/' then
        self.prompt = 'filter'
        self.before_query = self.query
        self.input = self.query
    elseif key == 'SPACE' then
        local group = self:selected()
        if group then
            self.marked[group] = not self.marked[group]
        end
    elseif key == 'e' then
        if self:selected() or next(self.marked) then
            self.prompt = 'export'
            self.input = ''
            self.status = 'Create a new JSON file; existing files are preserved'
        else
            self.status = 'No groups to export'
        end
    elseif key == '!' then
        self.view = 'errors'
        self.detail_scroll = 0
    elseif key == 'ENTER' then
        if self:selected() then
            self.view = 'details'
            self.detail_scroll = 0
        end
    else
        local field = self.pane == 'groups' and 'group' or 'file'
        local group = self:selected()
        local count = field == 'group' and #self.visible or group and #group.paths or 0
        local delta = ({
            UP = -1,
            DOWN = 1,
            PAGE_UP = -math.max(1, self.rows - 4),
            PAGE_DOWN = math.max(1, self.rows - 4),
            j = 1,
            k = -1,
        })[key]
        if key == 'HOME' then
            self[field] = 1
        elseif key == 'END' then
            self[field] = count
        elseif delta then
            self[field] = self[field] + delta
        end
        if field == 'group' then
            self.file, self.file_scroll = 1, 0
        end
    end
    self:clamp(self.cols, self.rows)
    return true
end
local function header(model)
    return string.format(
        'Duplicate Finder | %d groups | %d errors | %s redundant',
        #model.visible,
        #model.result.errors,
        human(model.result.redundant_bytes)
    )
end
function TUI.detail_lines(model, width)
    local lines = {}
    local function add(text)
        for _, line in ipairs(wrap(text, width)) do
            lines[#lines + 1] = line
        end
    end
    if model.view == 'help' then
        for _, line in ipairs(TUI.help_lines) do
            add(line)
        end
    elseif model.view == 'errors' then
        if #model.result.errors == 0 then
            add('No scan errors.')
        end
        for _, error in ipairs(model.result.errors) do
            add(error.path)
            add('  ' .. error.message)
            add('')
        end
    else
        local group = model:selected()
        if not group then
            add('No group selected.')
        else
            add(
                string.format(
                    '%d identical files | %.0f bytes each | %s redundant',
                    #group.paths,
                    group.size,
                    human(group.size * (#group.paths - 1))
                )
            )
            add('Selected file: ' .. (group.paths[model.file] or group.paths[1]))
            add('')
            for i, path in ipairs(group.paths) do
                add(tostring(i) .. '. ' .. path)
                add('')
            end
        end
    end
    return lines
end
function TUI.render_details(model, cols, rows)
    local width, frame = math.max(0, cols - 1), {}
    local lines = TUI.detail_lines(model, math.max(1, width))
    local offset = math.min(model.detail_scroll, math.max(0, #lines - math.max(1, rows - 4)))
    for y = 1, rows do
        local text = ''
        if y == 1 then
            text = header(model)
        elseif y == 2 then
            text = model.view == 'help' and 'Help - keys, scanning, and export'
                or model.view == 'errors' and 'Scan errors'
                or 'Group details'
        elseif y == rows then
            text = width >= 65
                    and 'Up/Down Scroll  PgUp/PgDn Page  Home/End  Enter/Esc Back  ? Help'
                or 'Up/Down Scroll  Enter/Esc Back  ? Help'
        elseif y == rows - 1 then
            text = string.format('Line %d of %d', offset + 1, #lines)
        else
            text = lines[offset + y - 2] or ''
        end
        frame[y] = TUI.fit(text, width)
    end
    return frame
end
function TUI.render_browse(model, cols, rows)
    local width, frame = math.max(0, cols - 1), {}
    local split = width >= 70
    local left = split and math.floor(width * 0.38) or width
    local group = model:selected()
    local function group_line(i)
        local g = model.visible[i]
        if not g then
            return ''
        end
        return (i == model.group and '> ' or '  ')
            .. (model.marked[g] and '[x] ' or '[ ] ')
            .. #g.paths
            .. ' files | '
            .. human(g.size * (#g.paths - 1))
    end
    local function file_line(i)
        return group and group.paths[i] and ((i == model.file and '> ' or '  ') .. group.paths[i])
            or ''
    end
    for y = 1, rows do
        local text = ''
        if model.prompt and rows <= 4 and y == rows then
            text = (model.prompt == 'filter' and '/' or 'e:')
                .. tail(model.input, math.max(1, width - 3))
                .. '_'
        elseif y == 1 then
            text = header(model)
        elseif y == 2 then
            local a = (model.pane == 'groups' and '* ' or '  ') .. 'Groups: redundant bytes'
            local b = (model.pane == 'files' and '* ' or '  ') .. 'Files'
            text = split and TUI.fit(a, left) .. ' | ' .. b or model.pane == 'groups' and a or b
        elseif y == rows then
            if model.prompt then
                if width < 65 then
                    text = model.prompt == 'filter' and 'Enter Keep  Esc Cancel'
                        or 'Enter Save  Esc Cancel'
                else
                    text = model.prompt == 'filter'
                            and 'Type to filter | Enter Keep | Esc Cancel | Backspace Erase'
                        or 'New filename | Enter Save | Esc Cancel | Existing files preserved'
                end
            elseif width >= 90 then
                text =
                    '? Help  Up/Down Move  Tab Pane  / Filter  Space Mark  Enter Details  e Export  ! Errors  q Quit'
            elseif width >= 60 then
                text = '? Help  Tab Pane  / Filter  Space Mark  e Export  ! Errors  q Quit'
            else
                text = '? Help  Tab Pane  / Filter  q Quit'
            end
        elseif y == rows - 1 then
            if model.prompt then
                text = (model.prompt == 'filter' and 'Filter: ' or 'Export JSON: ')
                    .. tail(model.input, math.max(1, width - 14))
                    .. '_'
            elseif model.query ~= '' then
                text = 'Filter: ' .. model.query .. ' | ' .. model.status
            else
                text = model.status
            end
        elseif split then
            text = TUI.fit(group_line(model.group_scroll + y - 2), left)
                .. ' | '
                .. file_line(model.file_scroll + y - 2)
        elseif model.pane == 'groups' then
            text = group_line(model.group_scroll + y - 2)
        else
            text = file_line(model.file_scroll + y - 2)
        end
        if y == 3 and #model.visible == 0 and rows > 4 then
            text = 'No duplicate groups match the filter.'
        end
        frame[y] = TUI.fit(text, width)
    end
    return frame
end
function TUI.render_progress(progress, cols, rows)
    local frame = {}
    local lines = {
        'Duplicate Finder | scanning',
        progress.phase or 'Scanning',
        string.format(
            '%d files | %d errors | %s read',
            progress.files or 0,
            progress.errors or 0,
            human(progress.bytes or 0)
        ),
        progress.path or '',
    }
    for y = 1, rows do
        frame[y] = TUI.fit(
            y == rows and 'q / Esc Cancel scan  Ctrl-C Exit' or lines[y] or '',
            math.max(0, cols - 1)
        )
    end
    return frame
end
function TUI.frame(model, cols, rows)
    if model.view == 'browse' then
        return TUI.render_browse(model, cols, rows)
    end
    return TUI.render_details(model, cols, rows)
end
function TUI.diff(frame, previous)
    local out = { '\27[?2026h' }
    local changed = false
    for row, line in ipairs(frame) do
        if not previous or line ~= previous[row] then
            out[#out + 1] = string.format('\27[%d;1H%s\27[K', row, line)
            changed = true
        end
    end
    if not changed then
        return ''
    end
    out[#out + 1] = '\27[?2026l'
    return table.concat(out)
end

-- Terminal adapters are lazy so CLI/JSON use never touches terminal settings.
function TUI.terminal(platform, native)
    platform = platform or ffi.os
    local term = { active = false, decode = TUI.decoder() }
    function term:write(text)
        if text ~= '' then
            assert(io.write(text))
            assert(io.flush())
        end
    end
    if platform == 'Windows' then
        ffi.cdef([[
            typedef struct {
                int16_t x, y;
            } DupCoord;
            typedef struct {
                int16_t left, top, right, bottom;
            } DupRect;
            typedef struct {
                DupCoord size, cursor;
                uint16_t attributes;
                DupRect window;
                DupCoord maximum;
            } DupConsoleInfo;
            typedef struct {
                int32_t down;
                uint16_t repeats, key, scan, unicode;
                uint32_t control;
            } DupKeyEvent;
            typedef struct {
                uint16_t type, padding;
                union {
                    DupKeyEvent key;
                    uint8_t other[16];
                } event;
            } DupInputRecord;
            void *__stdcall GetStdHandle(uint32_t);
            int __stdcall GetConsoleMode(void *, uint32_t *);
            int __stdcall SetConsoleMode(void *, uint32_t);
            int __stdcall GetConsoleScreenBufferInfo(void *, DupConsoleInfo *);
            int __stdcall GetNumberOfConsoleInputEvents(void *, uint32_t *);
            int __stdcall ReadConsoleInputW(void *, DupInputRecord *, uint32_t, uint32_t *);
            uint32_t __stdcall WaitForSingleObject(void *, uint32_t);
            uint64_t __stdcall GetTickCount64(void);
        ]])
        native = native or ffi.load('kernel32')
        term.input, term.output = native.GetStdHandle(0xfffffff6), native.GetStdHandle(0xfffffff5)
        term.inmode, term.outmode = ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]')
        function term:is_tty()
            return native.GetConsoleMode(self.input, self.inmode) ~= 0
                and native.GetConsoleMode(self.output, self.outmode) ~= 0
        end
        function term:now()
            return tonumber(native.GetTickCount64()) / 1000
        end
        function term:size()
            local info = ffi.new('DupConsoleInfo[1]')
            if native.GetConsoleScreenBufferInfo(self.output, info) ~= 0 then
                return math.max(1, tonumber(info[0].window.right - info[0].window.left + 1)),
                    math.max(1, tonumber(info[0].window.bottom - info[0].window.top + 1))
            end
            return 80, 24
        end
        function term:enter()
            assert(self:is_tty(), 'Windows console unavailable')
            self.codepage = native.GetConsoleOutputCP()
            self.active = true
            assert(
                native.SetConsoleMode(self.output, bit.bor(self.outmode[0], 4)) ~= 0,
                'Virtual terminal output unavailable'
            )
            local mode = bit.bor(bit.band(self.inmode[0], bit.bnot(0x247)), 0x88)
            assert(native.SetConsoleMode(self.input, mode) ~= 0, 'Cannot enable console input')
            assert(native.SetConsoleOutputCP(65001) ~= 0, 'Cannot enable UTF-8 output')
            self:write('\27[?2026h\27[?1049h\27[?25l\27[?7l\27[2J\27[?2026l')
        end
        function term:restore()
            if self.active then
                pcall(self.write, self, '\27[?2026l\27[0m\27[?7h\27[?1049l\27[?25h')
                native.SetConsoleMode(self.input, self.inmode[0])
                native.SetConsoleMode(self.output, self.outmode[0])
                native.SetConsoleOutputCP(self.codepage)
                self.active = false
            end
        end
        local function utf8(cp)
            if cp < 128 then
                return string.char(cp)
            elseif cp < 2048 then
                return string.char(192 + math.floor(cp / 64), 128 + cp % 64)
            elseif cp < 65536 then
                return string.char(
                    224 + math.floor(cp / 4096),
                    128 + math.floor(cp / 64) % 64,
                    128 + cp % 64
                )
            else
                return string.char(
                    240 + math.floor(cp / 262144),
                    128 + math.floor(cp / 4096) % 64,
                    128 + math.floor(cp / 64) % 64,
                    128 + cp % 64
                )
            end
        end
        function term:keys(timeout)
            local keys = {}
            local count, read_count = ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]')
            local record = ffi.new('DupInputRecord[1]')
            if timeout > 0 then
                native.WaitForSingleObject(self.input, timeout)
            end
            for _ = 1, 1024 do
                if native.GetNumberOfConsoleInputEvents(self.input, count) == 0 then
                    return { 'EOF' }
                end
                if count[0] == 0 then
                    break
                end
                if
                    native.ReadConsoleInputW(self.input, record, 1, read_count) == 0
                    or read_count[0] == 0
                then
                    return { 'EOF' }
                end
                if record[0].type == 1 and record[0].event.key.down ~= 0 then
                    local e = record[0].event.key
                    local key = ({
                        [38] = 'UP',
                        [40] = 'DOWN',
                        [37] = 'LEFT',
                        [39] = 'RIGHT',
                        [33] = 'PAGE_UP',
                        [34] = 'PAGE_DOWN',
                        [36] = 'HOME',
                        [35] = 'END',
                    })[tonumber(e.key)]
                    for _ = 1, math.max(1, tonumber(e.repeats)) do
                        local cp = tonumber(e.unicode)
                        if key then
                            keys[#keys + 1] = key
                        elseif cp >= 0xd800 and cp <= 0xdbff then
                            self.surrogate = cp
                        elseif cp >= 0xdc00 and cp <= 0xdfff and self.surrogate then
                            cp = 0x10000 + (self.surrogate - 0xd800) * 1024 + cp - 0xdc00
                            self.surrogate = nil
                            for _, k in ipairs(self.decode(utf8(cp), true)) do
                                keys[#keys + 1] = k
                            end
                        elseif cp ~= 0 then
                            self.surrogate = nil
                            for _, k in ipairs(self.decode(utf8(cp), true)) do
                                keys[#keys + 1] = k
                            end
                        end
                    end
                end
            end
            return keys
        end
    else
        ffi.cdef([[
            typedef struct {
                uint32_t iflag, oflag, cflag, lflag;
                uint8_t line, cc[32];
                uint32_t ispeed, ospeed;
            } DupTermios;
            typedef struct {
                int fd;
                int16_t events, revents;
            } DupPoll;
            typedef struct {
                uint16_t rows, cols, x, y;
            } DupWinSize;
            typedef struct {
                int64_t sec, nsec;
            } DupClock;
            int isatty(int);
            int tcgetattr(int, DupTermios *);
            int tcsetattr(int, int, const DupTermios *);
            void cfmakeraw(DupTermios *);
            int ioctl(int, unsigned long, ...);
            int poll(DupPoll *, unsigned long, int);
            int clock_gettime(int, DupClock *);
            typedef void (*dup_signal_handler)(int);
            dup_signal_handler signal(int, dup_signal_handler);
        ]])
        local C = ffi.C
        term.original = ffi.new('DupTermios[1]')
        function term:is_tty()
            return C.isatty(0) ~= 0 and C.isatty(1) ~= 0
        end
        function term:now()
            local time = ffi.new('DupClock[1]')
            assert(C.clock_gettime(1, time) == 0, 'Cannot read monotonic clock')
            return tonumber(time[0].sec) + tonumber(time[0].nsec) / 1000000000
        end
        function term:size()
            local size = ffi.new('DupWinSize[1]')
            if C.ioctl(1, 0x5413, size) == 0 and size[0].cols > 0 and size[0].rows > 0 then
                return tonumber(size[0].cols), tonumber(size[0].rows)
            end
            return 80, 24
        end
        function term:enter()
            assert(C.tcgetattr(0, self.original) == 0, 'Cannot read terminal settings')
            local raw = ffi.new('DupTermios[1]')
            ffi.copy(raw, self.original, ffi.sizeof(raw))
            C.cfmakeraw(raw)
            raw[0].cc[5], raw[0].cc[6] = 0, 0
            assert(C.tcsetattr(0, 0, raw) == 0, 'Cannot enable raw input')
            self.active = true
            self.callback = ffi.cast('dup_signal_handler', function(sig)
                self.stopped = 128 + sig
            end)
            self.old_int = C.signal(2, self.callback)
            self.old_term = C.signal(15, self.callback)
            self:write('\27[?2026h\27[?1049h\27[?25l\27[?7l\27[2J\27[?2026l')
        end
        function term:restore()
            if self.active then
                C.tcsetattr(0, 0, self.original)
                pcall(self.write, self, '\27[?2026l\27[0m\27[?7h\27[?1049l\27[?25h')
                self.active = false
            end
            if self.callback then
                C.signal(2, self.old_int)
                C.signal(15, self.old_term)
                self.callback:free()
                self.callback = nil
            end
        end
        function term:keys(timeout)
            local p = ffi.new('DupPoll[1]', { { 0, 1, 0 } })
            local buf = ffi.new('uint8_t[4096]')
            local keys = {}
            for _ = 1, 64 do
                local ready = C.poll(p, 1, timeout)
                timeout = 0
                if ready <= 0 then
                    break
                end
                if bit.band(p[0].revents, 1) ~= 0 then
                    local n = tonumber(C.read(0, buf, 4096))
                    if n <= 0 then
                        keys[#keys + 1] = 'EOF'
                        break
                    end
                    self.last_input = self:now()
                    for _, key in ipairs(self.decode(ffi.string(buf, n))) do
                        keys[#keys + 1] = key
                    end
                elseif bit.band(p[0].revents, 24) ~= 0 then
                    keys[#keys + 1] = 'EOF'
                    break
                else
                    break
                end
            end
            local flush = self.last_input and self:now() - self.last_input >= 0.03
            for _, key in ipairs(self.decode('', flush)) do
                keys[#keys + 1] = key
            end
            return keys
        end
    end
    return term
end

function TUI.run(api, roots, options, term)
    term = term or TUI.terminal()
    if not term:is_tty() then
        io.stderr:write(
            '--tui requires an interactive terminal (use CLI or --json for pipelines)\n'
        )
        return 2
    end
    local jit_enabled = require('jit').status()
    -- A Lua signal callback must never enter a compiled FFI call.
    require('jit').off()
    local result, previous, oldcols, oldrows, cancelled, exit_code
    local function emit(frame, cols, rows)
        local resized = oldcols and (oldcols ~= cols or oldrows ~= rows)
        if resized then
            previous = nil
        end
        local output = TUI.diff(frame, previous)
        if resized then
            output = output:gsub('^\27%[%?2026h', '\27[?2026h\27[2J', 1)
        end
        term:write(output)
        previous, oldcols, oldrows = frame, cols, rows
    end
    local ok, message = xpcall(function()
        term:enter()
        local last_frame = -math.huge
        local scan_options = { min_size = options.min_size }
        scan_options.progress = function(phase, path, bytes, r)
            local keys = term:keys(0)
            for _, key in ipairs(keys) do
                if key == 'q' or key == 'ESC' or key == 'EOF' or key == 'CTRL_C' then
                    cancelled = true
                    exit_code = key == 'CTRL_C' and 130 or 0
                end
            end
            if term.stopped then
                cancelled = true
                exit_code = term.stopped
            end
            if cancelled then
                return false
            end
            local now = term:now()
            if now - last_frame >= 0.05 then
                local cols, rows = term:size()
                emit(
                    TUI.render_progress({
                        phase = phase,
                        path = path,
                        bytes = bytes,
                        files = r.files,
                        errors = #r.errors,
                    }, cols, rows),
                    cols,
                    rows
                )
                last_frame = now
            end
            return true
        end
        result = api.scan(roots, scan_options)
        if cancelled or result.cancelled then
            return
        end
        local model = TUI.model(result)
        while not term.stopped do
            local cols, rows = term:size()
            model:clamp(cols, rows)
            emit(TUI.frame(model, cols, rows), cols, rows)
            local keys = term:keys(30)
            for _, key in ipairs(keys) do
                local running, effect = model:key(key)
                if not running then
                    exit_code = key == 'CTRL_C' and 130 or 0
                    return
                end
                if effect then
                    local saved, e = api.export_file(effect.path, effect.result)
                    model.status = saved and 'Saved: ' .. effect.path
                        or 'Export failed: ' .. tostring(e)
                end
                if model.filter_pending then
                    -- Echo first; filtering follows the prompt-only frame.
                    emit(TUI.frame(model, cols, rows), cols, rows)
                    model:filter()
                    model:clamp(cols, rows)
                end
            end
        end
        exit_code = term.stopped
    end, debug.traceback)
    term:restore()
    if jit_enabled then
        require('jit').on()
    end
    if not ok then
        io.stderr:write(message, '\n')
        return 1
    end
    return exit_code or (result and #result.errors > 0 and 1 or 0)
end

local function new(backend)
    local M = {}
    local metadata = backend.metadata

    local function open_checked(file)
        local fd, e = backend.open(file.path)
        if not fd then
            return nil, e
        end
        local s, e = metadata(file.path, fd)
        if not s or s.kind ~= 0x8000 or s.signature ~= file.signature then
            backend.close(fd)
            return nil, e or 'file changed during scan'
        end
        return fd
    end

    local function read_chunk(fd, buf)
        local used = 0
        while used < 65536 do
            local n, e = backend.read(fd, buf + used, 65536 - used)
            if not n then
                return nil, e
            end
            if n == 0 then
                break
            end
            used = used + n
        end
        return used
    end

    local function stable(file, fd)
        local s = metadata(file.path, fd)
        return s and s.signature == file.signature
    end

    function M.hash(file, progress)
        local fd, e = open_checked(file)
        if not fd then
            return nil, e
        end
        local buf, h, total = ffi.new('uint8_t[65536]'), 5381, 0
        while true do
            local n
            n, e = read_chunk(fd, buf)
            if not n then
                break
            end
            if n == 0 then
                break
            end
            if progress and progress(n) == false then
                backend.close(fd)
                return nil, 'Scan cancelled'
            end
            total = total + n
            for i = 0, n - 1 do
                h = bit.bxor(bit.tobit(h * 33), buf[i])
            end
        end
        local ok = stable(file, fd) and total == file.size
        backend.close(fd)
        if e or not ok then
            return nil, e or 'file changed during hashing'
        end
        return tostring(h)
    end

    function M.equal(a, b, progress)
        local fa, e = open_checked(a)
        if not fa then
            return nil, e, a
        end
        local fb
        fb, e = open_checked(b)
        if not fb then
            backend.close(fa)
            return nil, e, b
        end
        local ba, bb = ffi.new('uint8_t[65536]'), ffi.new('uint8_t[65536]')
        local same, total, failed_file = true, 0, nil
        while true do
            local na, ea = read_chunk(fa, ba)
            local nb, eb = read_chunk(fb, bb)
            if not na or not nb then
                same = nil
                e = ea or eb
                failed_file = not na and a or b
                break
            end
            if progress and progress(na + nb) == false then
                backend.close(fa)
                backend.close(fb)
                return nil, 'Scan cancelled', a
            end
            total = total + na
            if na ~= nb or ffi.C.memcmp(ba, bb, na) ~= 0 then
                same = false
                break
            end
            if na == 0 then
                break
            end
        end
        if not stable(a, fa) then
            same = nil
            e = 'file changed during comparison'
            failed_file = a
        elseif not stable(b, fb) then
            same = nil
            e = 'file changed during comparison'
            failed_file = b
        elseif same and total ~= a.size then
            same = nil
            e = 'file changed during comparison'
            failed_file = a
        end
        backend.close(fa)
        backend.close(fb)
        return same, e, failed_file
    end

    function M.scan(roots, options)
        options = options or {}
        local result =
            { groups = {}, errors = {}, files = 0, redundant_bytes = 0, skipped_links = 0 }
        local seen, dirs, sizes, pending = {}, {}, {}, {}
        local bytes_read = 0

        local function tick(phase, path, bytes)
            bytes_read = bytes_read + (bytes or 0)
            if options.progress and options.progress(phase, path, bytes_read, result) == false then
                result.cancelled = true
                return false
            end
            return true
        end

        local function warning(path, message)
            result.errors[#result.errors + 1] = { path = path, message = message }
        end
        for _, root in ipairs(roots) do
            pending[#pending + 1] = root
        end
        while #pending > 0 do
            local path = table.remove(pending)
            if not tick('Discovering files', path) then
                return result
            end
            local s, e = metadata(path)
            if not s then
                warning(path, e)
            elseif s.kind == 0xa000 then
                result.skipped_links = result.skipped_links + 1
            elseif s.kind == 0x4000 and not dirs[s.id] then
                dirs[s.id] = true
                local ok, message = backend.list(path, function(name)
                    local child = backend.join(path, name)
                    if not tick('Discovering files', child) then
                        return false
                    end
                    pending[#pending + 1] = child
                end)
                if result.cancelled then
                    return result
                end
                if not ok then
                    warning(path, message)
                end
            elseif s.kind == 0x8000 and not seen[s.id] then
                seen[s.id] = true
                s.path = path
                result.files = result.files + 1
                if s.size >= (options.min_size or 0) then
                    sizes[s.size] = sizes[s.size] or {}
                    table.insert(sizes[s.size], s)
                end
            end
        end
        for _, files in pairs(sizes) do
            if #files > 1 then
                table.sort(files, function(a, b)
                    return a.path < b.path
                end)
                local buckets = {}
                for _, file in ipairs(files) do
                    if not tick('Hashing candidates', file.path) then
                        return result
                    end
                    local hash, e = (options.hash or M.hash)(file, function(bytes)
                        return tick('Hashing candidates', file.path, bytes)
                    end)
                    if result.cancelled then
                        return result
                    end
                    if not hash then
                        warning(file.path, e)
                    else
                        buckets[hash] = buckets[hash] or {}
                        table.insert(buckets[hash], file)
                    end
                end
                for _, bucket in pairs(buckets) do
                    local groups = {}
                    for _, file in ipairs(bucket) do
                        local found, failed = false, false
                        for _, group in ipairs(groups) do
                            while #group > 0 do
                                local same, e, bad = M.equal(group[1], file, function(bytes)
                                    return tick('Comparing candidates', file.path, bytes)
                                end)
                                if result.cancelled then
                                    return result
                                end
                                if same == nil then
                                    warning(bad.path, e)
                                    if bad == file then
                                        failed = true
                                        break
                                    end
                                    table.remove(group, 1)
                                else
                                    if same then
                                        table.insert(group, file)
                                        found = true
                                    end
                                    break
                                end
                            end
                            if found or failed then
                                break
                            end
                        end
                        if not found and not failed then
                            groups[#groups + 1] = { file }
                        end
                    end
                    for _, group in ipairs(groups) do
                        if #group > 1 then
                            local paths = {}
                            for _, file in ipairs(group) do
                                paths[#paths + 1] = file.path
                            end
                            result.groups[#result.groups + 1] =
                                { size = group[1].size, paths = paths }
                            result.redundant_bytes = result.redundant_bytes
                                + group[1].size * (#group - 1)
                        end
                    end
                end
            end
        end
        table.sort(result.groups, function(a, b)
            if a.size ~= b.size then
                return a.size > b.size
            end
            return a.paths[1] < b.paths[1]
        end)
        table.sort(result.errors, function(a, b)
            return a.path < b.path
        end)
        return result
    end

    function M.render(r)
        local lines = {}
        for i, g in ipairs(r.groups) do
            lines[#lines + 1] =
                string.format('Group %d: %d files, %.0f bytes each', i, #g.paths, g.size)
            for _, path in ipairs(g.paths) do
                lines[#lines + 1] = '  ' .. string.format('%q', path):gsub('\\\n', '\\n')
            end
        end
        lines[#lines + 1] = string.format(
            '%d duplicate group(s); %.0f redundant content bytes; %d files scanned',
            #r.groups,
            r.redundant_bytes,
            r.files
        )
        return table.concat(lines, '\n') .. '\n'
    end
    -- Preserve valid UTF-8; replace invalid bytes only in display strings. Raw
    -- filename bytes are carried separately as hex whenever replacement occurs.
    local function json_string(value)
        local out, i, invalid = { '"' }, 1, false
        while i <= #value do
            local b = value:byte(i)
            if b < 128 then
                if b == 34 then
                    out[#out + 1] = '\\"'
                elseif b == 92 then
                    out[#out + 1] = '\\\\'
                elseif b < 32 then
                    out[#out + 1] = string.format('\\u%04x', b)
                else
                    out[#out + 1] = string.char(b)
                end
                i = i + 1
            else
                local n = b >= 194 and b <= 223 and 2
                    or b >= 224 and b <= 239 and 3
                    or b >= 240 and b <= 244 and 4
                    or 0
                local valid = n > 0 and i + n - 1 <= #value
                for j = 1, n - 1 do
                    local c = value:byte(i + j)
                    if not c or c < 128 or c > 191 then
                        valid = false
                    end
                end
                local second = value:byte(i + 1)
                if
                    (b == 224 and (not second or second < 160))
                    or (b == 237 and second and second > 159)
                    or (b == 240 and (not second or second < 144))
                    or (b == 244 and second and second > 143)
                then
                    valid = false
                end
                if valid then
                    out[#out + 1] = value:sub(i, i + n - 1)
                    i = i + n
                else
                    out[#out + 1] = '\\ufffd'
                    invalid = true
                    i = i + 1
                end
            end
        end
        out[#out + 1] = '"'
        return table.concat(out), invalid
    end

    local function hex_bytes(value)
        return (
            value:gsub('.', function(c)
                return string.format('%02x', c:byte())
            end)
        )
    end

    function M.to_json(r)
        local groups, errors = {}, {}
        for _, group in ipairs(r.groups) do
            local paths, raw_paths, invalid = {}, {}, false
            for _, path in ipairs(group.paths) do
                local encoded, bad = json_string(path)
                paths[#paths + 1] = encoded
                invalid = invalid or bad
            end
            if invalid then
                for _, path in ipairs(group.paths) do
                    raw_paths[#raw_paths + 1] = '"' .. hex_bytes(path) .. '"'
                end
            end
            groups[#groups + 1] = '{"size":'
                .. string.format('%.0f', group.size)
                .. ',"paths":['
                .. table.concat(paths, ',')
                .. ']'
                .. (invalid and ',"paths_hex":[' .. table.concat(raw_paths, ',') .. ']' or '')
                .. '}'
        end
        for _, error in ipairs(r.errors) do
            local path, bad_path = json_string(error.path)
            local message, bad_message = json_string(error.message)
            errors[#errors + 1] = '{"path":'
                .. path
                .. ',"message":'
                .. message
                .. (bad_path and ',"path_hex":"' .. hex_bytes(error.path) .. '"' or '')
                .. (bad_message and ',"message_hex":"' .. hex_bytes(error.message) .. '"' or '')
                .. '}'
        end
        return '{"groups":['
            .. table.concat(groups, ',')
            .. '],"errors":['
            .. table.concat(errors, ',')
            .. '],"files":'
            .. string.format('%.0f', r.files)
            .. ',"redundant_bytes":'
            .. string.format('%.0f', r.redundant_bytes)
            .. ',"skipped_links":'
            .. string.format('%.0f', r.skipped_links)
            .. '}'
    end

    function M.export_file(path, result)
        return backend.write_new(path, M.to_json(result) .. '\n')
    end

    function M.main(args)
        local roots, opts, json_output, tui = {}, {}, false, false
        local literal = false
        for _, a in ipairs(args) do
            if not literal and a == '--' then
                literal = true
            elseif not literal and (a == '--help' or a == '-h') then
                io.write(CLI_HELP)
                return 0
            elseif not literal and a == '--json' then
                json_output = true
            elseif not literal and a == '--tui' then
                tui = true
            elseif not literal and a:match('^%-%-min%-size=') then
                local value = a:match('^%-%-min%-size=(%d+)$')
                local n = tonumber(value)
                if not n or n > 9007199254740991 then
                    io.stderr:write('Invalid minimum size\n')
                    return 2
                end
                opts.min_size = n
            elseif not literal and a:sub(1, 1) == '-' then
                io.stderr:write('Unknown option: ', string.format('%q', a), '\n')
                return 2
            else
                roots[#roots + 1] = a
            end
        end
        if #roots == 0 then
            roots = { '.' }
        end
        if tui and json_output then
            io.stderr:write('--tui and --json cannot be combined\n')
            return 2
        end
        if tui then
            return TUI.run(M, roots, opts)
        end
        local r = M.scan(roots, opts)
        if json_output then
            io.write(M.to_json(r), '\n')
        else
            io.write(M.render(r))
        end
        for _, e in ipairs(r.errors) do
            io.stderr:write(string.format('%q: %q\n', e.path, e.message))
        end
        return #r.errors > 0 and 1 or 0
    end
    return M
end

local M = new(backend)
M.new = new
M.windows_backend = windows_backend
M.tui = TUI

local caller = debug.getinfo(2, 'f')
if ... == 'ffi_duplicates' and caller and caller.func == require then
    return M
end

local args, message = arg
if backend.arguments then
    args, message = backend.arguments(arg)
end
if not args then
    io.stderr:write(message, '\n')
    os.exit(2)
end

local restore = backend.console_utf8 and backend.console_utf8()
local code = M.main(args)
if restore then
    restore()
end
os.exit(code)
