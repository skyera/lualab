-- Winsock transport for the shared coroutine HTTP server. Console Ctrl-C is read
-- on the Lua thread, avoiding unsafe Lua callbacks on Windows control threads.
local ffi = require('ffi')
local bit = require('bit')
ffi.cdef[[
struct leaf_wsapollfd { uintptr_t fd; short events; short revents; };
struct leaf_key_event { unsigned short kind, padding; int down;
    unsigned short repeat_count, key, scan, character; unsigned long control; };
int __stdcall WSAStartup(unsigned short, void *);
int __stdcall WSACleanup(void);
int __stdcall WSAGetLastError(void);
uintptr_t __stdcall socket(int, int, int);
int __stdcall closesocket(uintptr_t);
int __stdcall ioctlsocket(uintptr_t, long, unsigned long *);
int __stdcall setsockopt(uintptr_t, int, int, const char *, int);
int __stdcall bind(uintptr_t, const void *, int);
int __stdcall listen(uintptr_t, int);
uintptr_t __stdcall accept(uintptr_t, void *, int *);
int __stdcall getsockname(uintptr_t, void *, int *);
int __stdcall recv(uintptr_t, char *, int, int);
int __stdcall send(uintptr_t, const char *, int, int);
uint16_t __stdcall htons(uint16_t);
uint16_t __stdcall ntohs(uint16_t);
uint32_t __stdcall htonl(uint32_t);
int __stdcall WSAPoll(struct leaf_wsapollfd *, unsigned long, int);
uint64_t __stdcall GetTickCount64(void);
void * __stdcall GetStdHandle(unsigned long);
int __stdcall GetConsoleMode(void *, unsigned long *);
int __stdcall SetConsoleMode(void *, unsigned long);
int __stdcall PeekConsoleInputW(void *, struct leaf_key_event *, unsigned long, unsigned long *);
int __stdcall ReadConsoleInputW(void *, struct leaf_key_event *, unsigned long, unsigned long *);
]]
local W, K = ffi.load('ws2_32'), ffi.load('kernel32')
local INVALID = ffi.cast('uintptr_t', -1)
local SIGNAL_FD = 2147483647
local M = { C = {} }
local C = M.C
local started, console, console_mode

function M.errno()
    local err = W.WSAGetLastError()
    return err == 10035 and 11 or err == 10004 and 4 or err
end

function M.now() return tonumber(K.GetTickCount64()) / 1000 end

function M.cleanup()
    if console then K.SetConsoleMode(console, console_mode); console = nil end
    if started then W.WSACleanup(); started = false end
end

local function nonblocking(fd)
    if fd == INVALID then return -1 end
    local enabled = ffi.new('unsigned long[1]', 1)
    if W.ioctlsocket(fd, bit.tobit(0x8004667e), enabled) ~= 0 then
        W.closesocket(fd); return -1
    end
    return tonumber(fd)
end

function C.socket(family, kind, protocol)
    if not started then
        local data = ffi.new('uint64_t[64]') -- large enough and aligned for WSADATA
        assert(W.WSAStartup(0x0202, data) == 0, 'Cannot initialize Winsock')
        started = true
    end
    return nonblocking(W.socket(family, bit.band(kind, 15), protocol))
end

function C.accept(fd) return nonblocking(W.accept(fd, nil, nil)) end
function C.close(fd)
    if fd == SIGNAL_FD then return 0 end
    return W.closesocket(fd)
end
function C.setsockopt(fd, _, option, value, size)
    -- Exclusive bind prevents another Windows process from stealing this address.
    return W.setsockopt(fd, 0xffff, option == 2 and -5 or option, ffi.cast('const char *', value), size)
end
function C.bind(fd, address, size) return W.bind(fd, address, size) end
function C.listen(fd, count) return W.listen(fd, count) end
function C.getsockname(fd, address, size) return W.getsockname(fd, address, ffi.cast('int *', size)) end
function C.recv(fd, buffer, size) return W.recv(fd, buffer, size, 0) end
function C.send(fd, buffer, size) return W.send(fd, buffer, size, 0) end
function C.htons(value) return W.htons(value) end
function C.ntohs(value) return W.ntohs(value) end
function C.htonl(value) return W.htonl(value) end
function C.sigemptyset() return 0 end
function C.sigaddset() return 0 end
function C.sigprocmask() return 0 end
function C.read() return 0 end

function C.signalfd()
    local handle, mode = K.GetStdHandle(0xfffffff6), ffi.new('unsigned long[1]')
    if K.GetConsoleMode(handle, mode) ~= 0 then
        console_mode = tonumber(mode[0])
        assert(K.SetConsoleMode(handle, bit.band(console_mode, bit.bnot(1))) ~= 0,
            'Cannot configure console Ctrl-C')
        console = handle
    end
    return SIGNAL_FD
end

local function interrupted()
    if not console then return false end
    local event, count = ffi.new('struct leaf_key_event[1]'), ffi.new('unsigned long[1]')
    while K.PeekConsoleInputW(console, event, 1, count) ~= 0 and count[0] > 0 do
        if K.ReadConsoleInputW(console, event, 1, count) == 0 then break end
        if event[0].kind == 1 and event[0].down ~= 0
            and (event[0].character == 3 or (event[0].key == 67 and bit.band(event[0].control, 12) ~= 0)) then
            return true
        end
    end
    return false
end

function M.poll(fds, count, timeout)
    local native = ffi.new('struct leaf_wsapollfd[?]', count)
    for index = 0, count - 1 do
        native[index].fd = fds[index].fd == SIGNAL_FD and INVALID or fds[index].fd
        native[index].events = bit.band(fds[index].events, 1) ~= 0 and 0x100
            or bit.band(fds[index].events, 4) ~= 0 and 0x10 or 0
    end
    local result = W.WSAPoll(native, count, timeout)
    for index = 0, count - 1 do
        local events = tonumber(native[index].revents)
        if fds[index].fd == SIGNAL_FD then
            fds[index].revents = interrupted() and 1 or 0
        else
            fds[index].revents = bit.bor(bit.band(events, 0x300) ~= 0 and 1 or 0,
                bit.band(events, 0x10) ~= 0 and 4 or 0, bit.band(events, 7) ~= 0 and 8 or 0)
        end
    end
    return result
end
return M
