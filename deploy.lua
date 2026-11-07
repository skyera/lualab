#!/usr/bin/env luajit
--[[
    deploy.lua
    Installs lualab tools plus thin launchers, so they can be started by typing
    `pix`, `lumina`, `yt`, `weblite` / `wl`, `luatop` / `ltop`, `hwtui`, `codefind`,
    `logexplorer`, or `mdview` (see --help for the full app list):

      Linux / macOS : ~/bin/<app>.lua  + ~/bin/<app>      (POSIX sh, made executable)
      Windows       : C:\app\bin\<app>.lua + <app>.cmd    (cmd.exe / PowerShell)
                      C:\app\bin\<app>     (Git Bash / MSYS sh)

    Usage:
      luajit deploy.lua                     Install all tools for the current OS
      luajit deploy.lua --app <name|all>    Select a tool, e.g. mdview (default: all)
      luajit deploy.lua --dir <path>        Install into a custom directory
      luajit deploy.lua --os windows        Generate the Windows layout (e.g. from Linux/CI)
      luajit deploy.lua --check             Report only, write nothing
      luajit deploy.lua -h                  Show usage

    Local modules an app requires (e.g. termkit.lua for luatop and hwtui, json.lua for the
    web servers) are found by scanning its source for require("name") / pcall(require,
    "name") and copied next to it, transitively. Files loaded any other way go in the
    app's `deps` list in the registry below.

    The launcher prefers the `luajit` found on PATH ($<APP>_LUAJIT overrides it) and falls back to the
    absolute luajit that ran this deploy, so launchers keep working when luajit is not on PATH.
]]

local ffi = require("ffi")
local bit = require("bit")

-- =========================================================================
-- 1. Options & Registry
-- =========================================================================
-- Registry fields: id, name, script, desc, env_var, aliases (extra launcher names) and
-- deps (extra files the script loads WITHOUT a literal require, e.g. via dofile or a
-- computed name) and system_modules (required modules installed system-wide, so no file
-- is expected). Modules loaded with require("name") or pcall(require, "name") are
-- discovered automatically from the script's source (see discover_dependencies).
local APPS = {
    pix = {
        id = "pix",
        name = "pix",
        script = "pix.lua",
        desc = "Terminal Directory Image Viewer",
        env_var = "PIX_LUAJIT",
    },
    lumina = {
        id = "lumina",
        name = "lumina",
        script = "lumina.lua",
        desc = "Miller-Columns Terminal File Manager",
        env_var = "LUMINA_LUAJIT",
    },
    yt = {
        id = "yt",
        name = "yt",
        script = "yt.lua",
        desc = "YouTube & YouTube Music Terminal Player",
        env_var = "YT_LUAJIT",
    },
    weblite = {
        id = "weblite",
        name = "weblite",
        script = "weblite.lua",
        desc = "Vim-Driven Terminal Web Browser",
        env_var = "WEBLITE_LUAJIT",
        aliases = { "wl" },
    },
    luatop = {
        id = "luatop",
        name = "luatop",
        script = "luatop.lua",
        desc = "Real-Time Terminal System & Hardware Monitor",
        env_var = "LUATOP_LUAJIT",
        aliases = { "ltop" },
    },
    hwtui = {
        id = "hwtui",
        name = "hwtui",
        script = "hwinfo_tui.lua",
        desc = "Tabbed Hardware Inventory Viewer",
        env_var = "HWTUI_LUAJIT",
    },
    logexplorer = {
        id = "logexplorer",
        name = "logexplorer",
        script = "ffi_log_explorer.lua",
        desc = "Live Terminal Log Explorer",
        env_var = "LOGEXPLORER_LUAJIT",
    },
    mdview = {
        id = "mdview",
        name = "mdview",
        script = "mdview.lua",
        desc = "Terminal Markdown Viewer",
        env_var = "MDVIEW_LUAJIT",
    },
    codefind = {
        id = "codefind",
        name = "codefind",
        script = "codefind.lua",
        desc = "Local Code & Document Full-Text Search",
        env_var = "CODEFIND_LUAJIT",
    },
    codefind_web = {
        id = "codefind_web",
        name = "codefind_web",
        script = "codefind_web.lua",
        desc = "Local Code & Document Search Engine Web Server",
        env_var = "CODEFIND_WEB_LUAJIT",
        aliases = { "cfweb" },
    },
    landrop = {
        id = "landrop",
        name = "landrop",
        script = "landrop_web.lua",
        desc = "LAN File Drop & Cross-Device Clipboard Web Server",
        env_var = "LANDROP_LUAJIT",
        aliases = { "ldrop" },
    },
    ytweb = {
        id = "ytweb",
        name = "ytweb",
        script = "yt-web.lua",
        desc = "YouTube & YouTube Music In-Browser Streaming Web Server",
        env_var = "YTWEB_LUAJIT",
        aliases = { "yt-web" },
    },
    pixweb = {
        id = "pixweb",
        name = "pixweb",
        script = "pix-web.lua",
        desc = "In-Browser Media Gallery & Streaming Web Server",
        env_var = "PIXWEB_LUAJIT",
        aliases = { "pix-web" },
    },
}

-- Deployment order for `--app all`.
local APP_ORDER = {
    "pix", "lumina", "yt", "weblite", "luatop", "hwtui", "codefind", "codefind_web",
    "landrop", "ytweb", "pixweb", "logexplorer", "mdview",
}

--- Find an app by its id or one of its launcher aliases; nil when unknown.
local function find_app(name)
    if APPS[name] then
        return APPS[name]
    end
    for _, app in pairs(APPS) do
        for _, alias in ipairs(app.aliases or {}) do
            if alias == name then
                return app
            end
        end
    end
    return nil
end

--- Comma-separated list of valid `--app` values for messages.
local function app_choices()
    return "all, " .. table.concat(APP_ORDER, ", ")
end

local opts = {
    app = "all",
    dir = nil,
    os = nil,
    check = false,
}

local function print_usage()
    print("lualab deploy — Cross-Platform Tools Deployer (LuaJIT FFI)")
    print("Usage:")
    print("  luajit deploy.lua [--app " .. app_choices():gsub(", ", "|") .. "]"
        .. " [--dir <path>] [--os linux|windows] [--check]")
    print("")
    print("  --app <name>    App to deploy (default: all): " .. app_choices())
    print("                  aliases: wl, ltop, cfweb, ldrop, yt-web, pix-web")
    print("  --dir <path>    Target directory (default: C:\\app\\bin on Windows, ~/bin elsewhere)")
    print("  --os <name>     Force the target layout: linux (POSIX) or windows")
    print("  --check         Show what would be installed without writing anything")
end

-- =========================================================================
-- 1b. Platform layer (Windows wide-character APIs)
-- =========================================================================
-- LuaJIT on Windows hands `arg` and io.open the ANSI code page, which turns characters
-- such as CJK into "?" and cannot open such paths. So on Windows every path and argument
-- is kept as UTF-8 and converted to UTF-16 for the Win32 / CRT wide-character APIs.
local host_is_windows = (ffi.os == "Windows")
local SEP = host_is_windows and "\\" or "/"

local CP_UTF8 = 65001
local PATH_BUFFER_CHARS = 32768
local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
local FILE_ATTRIBUTE_DIRECTORY = 0x10
local SEEK_END = 2
local READ_CHUNK = 64 * 1024

local shell32 = nil
if host_is_windows then
    ffi.cdef[[
        uint32_t GetCurrentDirectoryW(uint32_t nBufferLength, wchar_t *lpBuffer);
        uint32_t GetModuleFileNameW(void *hModule, wchar_t *lpFilename, uint32_t nSize);
        uint32_t GetFileAttributesW(const wchar_t *lpFileName);
        int CreateDirectoryW(const wchar_t *lpPathName, void *lpSecurityAttributes);
        uint32_t GetLastError(void);
        const wchar_t *GetCommandLineW(void);
        void *LocalFree(void *hMem);
        int MultiByteToWideChar(uint32_t cp, uint32_t flags, const char *src, int srcLen,
                                wchar_t *dst, int dstLen);
        int WideCharToMultiByte(uint32_t cp, uint32_t flags, const wchar_t *src, int srcLen,
                                char *dst, int dstLen, const char *defaultChar, int *used);
        wchar_t **CommandLineToArgvW(const wchar_t *lpCmdLine, int *pNumArgs);
        void *_wfopen(const wchar_t *filename, const wchar_t *mode);
        size_t fread(void *buf, size_t size, size_t count, void *stream);
        size_t fwrite(const void *buf, size_t size, size_t count, void *stream);
        int fclose(void *stream);
        int _fseeki64(void *stream, int64_t offset, int origin);
        int64_t _ftelli64(void *stream);
    ]]
    shell32 = ffi.load("shell32")
else
    ffi.cdef[[
        char *getcwd(char *buf, size_t size);
    ]]
end

--- UTF-8 string -> NUL-terminated wchar_t[] (Windows only).
local function to_wide(text)
    local count = ffi.C.MultiByteToWideChar(CP_UTF8, 0, text, #text, nil, 0)
    local buf = ffi.new("wchar_t[?]", count + 1)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, text, #text, buf, count)
    return buf
end

--- NUL-terminated wchar_t* -> UTF-8 string (Windows only).
local function from_wide(wide)
    local count = ffi.C.WideCharToMultiByte(CP_UTF8, 0, wide, -1, nil, 0, nil, nil)
    if count <= 1 then
        return ""
    end
    local buf = ffi.new("char[?]", count)
    ffi.C.WideCharToMultiByte(CP_UTF8, 0, wide, -1, buf, count, nil, nil)
    return ffi.string(buf, count - 1)
end

-- Minimal io-file lookalike over a CRT FILE* opened with _wfopen, offering only the
-- methods this script uses: read(count | "*a"), write, seek("end") and close.
local WideFile = {}
WideFile.__index = WideFile

function WideFile:read(what)
    if what == "*a" then
        local chunks = {}
        while true do
            local chunk = self:read(READ_CHUNK)
            if not chunk then
                break
            end
            chunks[#chunks + 1] = chunk
        end
        return table.concat(chunks)
    end
    local buf = ffi.new("char[?]", what)
    local got = tonumber(ffi.C.fread(buf, 1, what, self.stream))
    if got == 0 then
        return nil
    end
    return ffi.string(buf, got)
end

function WideFile:write(data)
    if tonumber(ffi.C.fwrite(data, 1, #data, self.stream)) ~= #data then
        return nil, "short write"
    end
    return self
end

--- Moves to the end of the file and returns its length (the only supported seek).
function WideFile:seek(whence)
    assert(whence == "end", "WideFile:seek supports only 'end'")
    ffi.C._fseeki64(self.stream, 0, SEEK_END)
    return tonumber(ffi.C._ftelli64(self.stream))
end

function WideFile:close()
    return ffi.C.fclose(self.stream) == 0
end

--- Opens a file by UTF-8 path; same contract as io.open (file or nil, err).
local function open_file(path, mode)
    if not host_is_windows then
        return io.open(path, mode)
    end
    local stream = ffi.C._wfopen(to_wide(path), to_wide(mode))
    if stream == nil then
        return nil, "cannot open " .. path
    end
    return setmetatable({ stream = stream }, WideFile)
end

--- Script arguments and script path as UTF-8. Returns args (1-based list), script_path.
--- Falls back to the ANSI `arg` table (and says so) if the wide command line is unavailable.
local function script_arguments()
    local ansi = arg or {}
    if not host_is_windows then
        return ansi, ansi[0]
    end
    local count = ffi.new("int[1]")
    local wide_argv = shell32.CommandLineToArgvW(ffi.C.GetCommandLineW(), count)
    if wide_argv == nil or count[0] < #ansi + 1 then
        io.stderr:write("deploy: warning: cannot read the Unicode command line;"
            .. " non-ANSI characters in arguments may be lost\n")
        return ansi, ansi[0]
    end
    local all = {}
    for i = 0, count[0] - 1 do
        all[#all + 1] = from_wide(wide_argv[i])
    end
    ffi.C.LocalFree(wide_argv)
    local args = {}
    for i = 1, #ansi do
        args[i] = all[#all - #ansi + i]
    end
    return args, all[#all - #ansi]
end

local argv, SCRIPT_PATH = script_arguments()

do
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--app" then
            i = i + 1
            opts.app = (argv[i] or "all"):lower()
        elseif a:match("^%-%-app=") then
            opts.app = a:sub(7):lower()
        elseif a == "--dir" then
            i = i + 1
            opts.dir = argv[i]
        elseif a:match("^%-%-dir=") then
            opts.dir = a:sub(7)
        elseif a == "--os" then
            i = i + 1
            opts.os = argv[i]
        elseif a:match("^%-%-os=") then
            opts.os = a:sub(5)
        elseif a == "--check" or a == "-n" then
            opts.check = true
        elseif a == "-h" or a == "--help" then
            print_usage()
            os.exit(0)
        else
            io.stderr:write("deploy: unknown argument '" .. tostring(a) .. "'\n")
            print_usage()
            os.exit(2)
        end
        i = i + 1
    end
end

if opts.app ~= "all" and not find_app(opts.app) then
    io.stderr:write("deploy: unknown --app '" .. tostring(opts.app) .. "' (use " .. app_choices() .. ")\n")
    os.exit(2)
end

local target_os = (opts.os or (ffi.os == "Windows" and "windows") or "linux"):lower()
if target_os ~= "windows" and target_os ~= "linux" and target_os ~= "posix" then
    io.stderr:write("deploy: unsupported --os '" .. target_os .. "' (use linux or windows)\n")
    os.exit(2)
end

-- Two distinct notions: this filesystem (host) uses / or \, while the deployed layout (target)
-- decides which launchers to write and which PATH syntax to advise.
local target_is_windows = (target_os == "windows")

-- =========================================================================
-- 2. Filesystem & path helpers
-- =========================================================================
local function file_exists(path)
    local f = open_file(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function file_size(path)
    local f = open_file(path, "rb")
    if not f then
        return nil
    end
    local n = f:seek("end")
    f:close()
    return n
end

local function format_size(n)
    if not n then return "-" end
    if n < 1024 then return string.format("%d B", n) end
    if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
    return string.format("%.2f MB", n / (1024 * 1024))
end

--- Copies src to dst. Returns true, bytes_copied or false, reason.
local function copy_file(src, dst)
    local in_f = open_file(src, "rb")
    if not in_f then
        return false, "cannot read " .. src
    end
    local out_f = open_file(dst, "wb")
    if not out_f then
        in_f:close()
        return false, "cannot write " .. dst
    end

    local total = 0
    local failure = nil
    while true do
        local chunk = in_f:read(READ_CHUNK)
        if not chunk then
            break
        end
        local ok, err = out_f:write(chunk)
        if not ok then
            failure = "cannot write " .. dst .. ": " .. tostring(err)
            break
        end
        total = total + #chunk
    end
    in_f:close()
    if not out_f:close() and not failure then
        failure = "cannot finish writing " .. dst
    end
    if failure then
        return false, failure
    end
    return true, total
end

--- Writes data to path. Returns true or false, reason.
local function write_file(path, data)
    local f, open_err = open_file(path, "wb")
    if not f then
        return false, open_err
    end
    local ok, write_err = f:write(data)
    local closed = f:close()
    if not ok then
        return false, write_err
    end
    if not closed then
        return false, "cannot finish writing " .. path
    end
    return true
end

-- Plain "r" mode: POSIX popen() rejects "rb" (glibc >= 2.34 returns EINVAL).
local function command_output(cmd)
    local p = io.popen(cmd, "r")
    if not p then return nil end
    local out = p:read("*l")
    p:close()
    if out then out = out:gsub("[\r\n]+$", "") end
    if out == "" then return nil end
    return out
end

local function get_cwd()
    if host_is_windows then
        local buf = ffi.new("wchar_t[?]", PATH_BUFFER_CHARS)
        local len = ffi.C.GetCurrentDirectoryW(PATH_BUFFER_CHARS, buf)
        if len > 0 and len < PATH_BUFFER_CHARS then
            return from_wide(buf)
        end
        local cwd = command_output("cd")
        if cwd and cwd ~= "" then
            return cwd
        end
        return "."
    end
    local buf = ffi.new("char[4096]")
    if ffi.C.getcwd(buf, 4096) ~= nil then
        return ffi.string(buf)
    end
    local cwd = os.getenv("PWD") or command_output("pwd")
    if not cwd or cwd == "" then
        cwd = "."
    end
    return cwd
end

local function normalize_dir(path)
    if not path or path == "" then return path end
    path = path:gsub("^%s+", ""):gsub("%s+$", "")
    path = path:gsub('"', ""):gsub("'", "")
    if host_is_windows then
        local drive, rest = path:match("^[/\\](%a)([/\\].*)$")
        if drive then
            path = drive:upper() .. ":" .. rest
        else
            local bare_drive = path:match("^[/\\](%a)$")
            if bare_drive then
                path = bare_drive:upper() .. ":\\"
            end
        end
        path = path:gsub("/", "\\")
        path = path:gsub("\\+$", "")
        if path:match("^%a:$") then
            path = path .. "\\"
        end
        if path == "" then path = "\\" end
    else
        path = path:gsub("\\", "/")
        path = path:gsub("//+", "/")
        path = path:gsub("/%./", "/")
        path = path:gsub("/%.$", "")
        path = path:gsub("/+$", "")
        if path == "" then path = "/" end
    end
    return path
end

local function is_absolute(path)
    return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
end

-- Directory holding this script (deploy.lua), used to locate pix.lua
local function get_script_dir()
    local candidates = {}
    local function add_candidate(dir)
        if not dir or dir == "" then
            return
        end
        local norm = is_absolute(dir) and normalize_dir(dir) or normalize_dir(get_cwd() .. SEP .. dir)
        table.insert(candidates, norm)
    end

    local self_path = SCRIPT_PATH or "deploy.lua"
    add_candidate(self_path:match("^(.*)[/\\][^/\\]*$"))

    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        local src = info.source:sub(2)
        add_candidate(src:match("^(.*)[/\\][^/\\]*$"))
    end

    table.insert(candidates, normalize_dir(get_cwd()))
    table.insert(candidates, ".")

    for _, cand in ipairs(candidates) do
        for _, app in pairs(APPS) do
            if file_exists(cand .. SEP .. app.script) then
                return cand
            end
        end
    end
    return candidates[1] or normalize_dir(get_cwd())
end

-- Absolute path of the luajit that is running this deploy (bare names resolved via PATH)
local function resolve_luajit()
    if host_is_windows then
        local buf = ffi.new("wchar_t[?]", PATH_BUFFER_CHARS)
        local len = ffi.C.GetModuleFileNameW(nil, buf, PATH_BUFFER_CHARS)
        if len > 0 and len < PATH_BUFFER_CHARS then
            local exe = from_wide(buf)
            if exe:lower():find("luajit", 1, true) then
                return normalize_dir(exe)
            end
        end
    end
    local interp = (arg and arg[-1]) or ""
    if interp == "" then interp = "luajit" end

    if not interp:find("[/\\]") then
        local probe = host_is_windows
            and ("where " .. interp .. " 2>nul")
            or ("command -v " .. interp .. " 2>/dev/null")
        return command_output(probe) or interp
    end

    if not is_absolute(interp) then
        interp = get_cwd() .. SEP .. interp:gsub("^%.[/\\]", "")
    end
    return normalize_dir(interp)
end

local function default_target_dir()
    if target_is_windows then return "C:\\app\\bin" end
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if not home or home == "" then return get_cwd() .. "/bin" end
    return normalize_dir(home) .. "/bin"
end

--- True when path is an existing directory (Windows only).
local function windows_dir_exists(path)
    local attrs = ffi.C.GetFileAttributesW(to_wide(path))
    return attrs ~= INVALID_FILE_ATTRIBUTES and bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0
end

--- Creates path and any missing parents (Windows only). Returns true or false, reason.
local function windows_make_dirs(path)
    if windows_dir_exists(path) then
        return true
    end
    local parent = path:match("^(.*)[/\\][^/\\]+$")
    if parent and parent ~= "" and not parent:match("^%a:$") then
        local ok, err = windows_make_dirs(parent)
        if not ok then
            return false, err
        end
    end
    if ffi.C.CreateDirectoryW(to_wide(path), nil) == 0 then
        return false, string.format("CreateDirectoryW failed for %s (Windows error %d)",
            path, ffi.C.GetLastError())
    end
    return true
end

--- Creates the directory and its parents. Returns true or false, reason.
local function ensure_dir(path)
    if host_is_windows then
        return windows_make_dirs(path)
    end
    local status = os.execute(string.format('mkdir -p "%s" 2>/dev/null', path))
    if status ~= 0 and status ~= true then
        return false, "mkdir -p failed for " .. path
    end
    return true
end

local function dir_in_path(dir)
    local path_env = os.getenv("PATH") or ""
    local target = normalize_dir(dir)
    local sep = target_is_windows and ";" or ":"

    for entry in path_env:gmatch("[^" .. sep .. "]+") do
        local candidate = normalize_dir(entry)
        if target_is_windows then
            if candidate:lower() == target:lower() then return true end
        elseif candidate == target then
            return true
        end
    end
    return false
end

-- Real I/O always uses host separators; messages spell paths the way the target OS does.
local function display_path(path)
    if target_is_windows then return (path:gsub("/", "\\")) end
    return path
end

-- =========================================================================
-- 3. Launcher templates
-- =========================================================================
local function posix_launcher(app, luajit_path, script_path)
    return table.concat({
        "#!/bin/sh",
        "# " .. app.name .. " - " .. app.desc .. " (installed by deploy.lua)",
        "# Prefers luajit from PATH ($" .. app.env_var .. " overrides it); falls back to the luajit used to deploy.",
        app.name:upper() .. '_FALLBACK_LUAJIT="' .. luajit_path .. '"',
        'LUAJIT="${' .. app.env_var .. ':-}"',
        'if [ -z "$LUAJIT" ]; then',
        '    if command -v luajit >/dev/null 2>&1; then LUAJIT=luajit; else LUAJIT="$' .. app.name:upper() .. '_FALLBACK_LUAJIT"; fi',
        'fi',
        'if ! command -v "$LUAJIT" >/dev/null 2>&1 && [ ! -x "$LUAJIT" ]; then',
        '    echo "' .. app.name .. ': luajit not found - set ' .. app.env_var .. '=/path/to/luajit" >&2',
        '    exit 127',
        'fi',
        'exec "$LUAJIT" "' .. script_path .. '" "$@"',
        "",
    }, "\n")
end

-- cmd.exe needs CRLF line endings. The script is located through %~dps0 (8.3 short form of the
-- launcher directory) because luajit.exe opens its script via the ANSI API and cannot open
-- paths with characters outside the system code page; the short path is plain ASCII.
local function windows_cmd_launcher(app, luajit_path)
    return table.concat({
        "@echo off",
        "chcp 65001 >nul 2>nul",
        "rem " .. app.name .. " - " .. app.desc .. " (installed by deploy.lua)",
        'set "' .. app.name:upper() .. '_FALLBACK_LUAJIT=' .. luajit_path .. '"',
        'set "LUAJIT=%' .. app.env_var .. '%"',
        'if not defined LUAJIT set "LUAJIT=luajit"',
        'where "%LUAJIT%" >nul 2>nul',
        'if errorlevel 1 set "LUAJIT=%' .. app.name:upper() .. '_FALLBACK_LUAJIT%"',
        'where "%LUAJIT%" >nul 2>nul',
        'if errorlevel 1 (',
        '    echo ' .. app.name .. ': luajit not found - set ' .. app.env_var .. ' to the luajit executable 1>&2',
        '    exit /b 127',
        ')',
        '"%LUAJIT%" "%~dps0' .. app.script .. '" %*',
        "",
    }, "\r\n")
end

-- =========================================================================
-- 3b. Dependency discovery
-- =========================================================================
local function read_file(path)
    local f = open_file(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

-- Modules provided by LuaJIT itself; a require of these never needs a file.
local BUILTIN_MODULES = {
    ffi = true, bit = true, jit = true, string = true, table = true, math = true,
    io = true, os = true, coroutine = true, debug = true, package = true,
}

--- Remove comments and long strings ([[...]]) so text inside them is not mistaken for
--- code (e.g. an embedded helper script that contains its own require calls).
local function strip_non_code(source)
    source = source:gsub("%-%-%[(=*)%[.-%]%1%]", "")
    source = source:gsub("\n[ \t]*%-%-[^\n]*", "\n")
    source = source:gsub("%[(=*)%[.-%]%1%]", "")
    return source
end

--- Modules a Lua source loads with a literal name. Returns two lists: required ones,
--- from require("name") / require "name", and optional ones, from pcall(require, "name").
local function required_modules(source)
    source = strip_non_code(source)
    local required, optional = {}, {}
    for name in source:gmatch("pcall%s*%(%s*require%s*,%s*[\"']([%w_%-]+)[\"']") do
        optional[#optional + 1] = name
    end
    source = source:gsub("pcall%s*%(%s*require%s*,", "")
    for name in source:gmatch("require%s*%(?%s*[\"']([%w_%-]+)[\"']") do
        required[#required + 1] = name
    end
    return required, optional
end

--- Files an app needs next to its script: its registry `deps` plus every local module
--- (a .lua file beside deploy.lua) that it or those modules load, transitively. Test
--- modules (test_*.lua) are never installed. Returns the file list and a list of
--- "module (required by file)" strings for required modules that cannot be found:
--- neither builtin, nor listed in the app's `system_modules`, nor present as a file.
local function discover_dependencies(app, source_dir)
    local system_modules = {}
    for _, name in ipairs(app.system_modules or {}) do
        system_modules[name] = true
    end
    local found, ordered, missing, queue = {}, {}, {}, {}
    local function add(file, path)
        if not found[file] and file ~= app.script then
            found[file] = true
            ordered[#ordered + 1] = file
            queue[#queue + 1] = path
        end
    end
    for _, file in ipairs(app.deps or {}) do
        add(file, source_dir .. SEP .. file)
    end
    local pending = { { path = app.source_path, file = app.script } }
    while #pending > 0 or #queue > 0 do
        local current = table.remove(pending) or { path = table.remove(queue) }
        current.file = current.file or current.path:match("([^/\\]+)$")
        local required, optional = required_modules(read_file(current.path) or "")
        for _, group in ipairs({ { required, true }, { optional, false } }) do
            for _, name in ipairs(group[1]) do
                local file = name .. ".lua"
                local candidate = source_dir .. SEP .. file
                if file_exists(candidate) then
                    if not name:match("^test_") then
                        add(file, candidate)
                    end
                elseif group[2] and not BUILTIN_MODULES[name] and not system_modules[name] then
                    missing[#missing + 1] = string.format("%s (required by %s)", name, current.file)
                end
            end
        end
    end
    return ordered, missing
end

-- =========================================================================
-- 4. Deploy
-- =========================================================================
local kind = target_is_windows and "Windows" or "Linux/POSIX"
local script_dir = get_script_dir()
local target_dir = normalize_dir(opts.dir or default_target_dir())
local luajit_path = resolve_luajit()

local apps_to_deploy = {}
if opts.app == "all" then
    for _, id in ipairs(APP_ORDER) do
        table.insert(apps_to_deploy, APPS[id])
    end
else
    table.insert(apps_to_deploy, find_app(opts.app))
end

print("lualab deploy — Cross-Platform Suite (LuaJIT FFI)")
print("  Target : " .. target_dir .. "   (" .. kind .. ")")
print("  Runtime: " .. luajit_path)
print("")

local available_apps = {}
local skipped_apps = {}
for _, app in ipairs(apps_to_deploy) do
    app.source_path = script_dir .. SEP .. app.script
    app.installed_lua = target_dir .. SEP .. app.script
    if file_exists(app.source_path) then
        local missing
        app.dependencies, missing = discover_dependencies(app, script_dir)
        if #missing > 0 then
            io.stderr:write(string.format("deploy: %s cannot be installed - missing module(s): %s\n",
                app.name, table.concat(missing, ", ")))
            io.stderr:write("  Put the module's .lua file next to deploy.lua, or list it under"
                .. " system_modules in the app registry if it is installed system-wide.\n")
            os.exit(1)
        end
        table.insert(available_apps, app)
    elseif opts.app == "all" then
        table.insert(skipped_apps, app)
    else
        io.stderr:write("deploy: " .. app.script .. " not found next to deploy.lua (" .. app.source_path .. ")\n")
        os.exit(1)
    end
end

if #available_apps == 0 then
    io.stderr:write("deploy: no tool scripts found next to deploy.lua (searched: " .. display_path(script_dir) .. ")\n")
    io.stderr:write("  Ensure the .lua tool scripts (e.g. pix.lua, mdview.lua) are in the same directory as deploy.lua.\n")
    os.exit(1)
end
if #skipped_apps > 0 then
    for _, app in ipairs(skipped_apps) do
        print(string.format("  [skip] %s not found in %s (skipping %s)", app.script, display_path(script_dir), app.name))
    end
    print("")
end
apps_to_deploy = available_apps

-- -------------------------------------------------------------------------
-- --check: report the planned actions and stop
-- -------------------------------------------------------------------------
if opts.check then
    for _, app in ipairs(apps_to_deploy) do
        print(string.format("[%s] %s", app.name, app.desc))
        local existing = file_size(app.installed_lua)
        local verb = existing and "overwrite" or "create"
        print(string.format("  [check] would %s %s (%s)", verb, display_path(app.installed_lua),
            existing and (format_size(existing) .. " -> " .. format_size(file_size(app.source_path))) or format_size(file_size(app.source_path))))
        for _, dep in ipairs(app.dependencies) do
            print(string.format("  [check] would copy      %s (dependency)",
                display_path(target_dir .. SEP .. dep)))
        end
        print(string.format("  [check] would write     %s", display_path(target_dir .. SEP .. app.name)))
        if target_is_windows then
            print(string.format("  [check] would write     %s", display_path(target_dir .. SEP .. app.name .. ".cmd")))
        end
        if app.aliases then
            for _, alias in ipairs(app.aliases) do
                print(string.format("  [check] would write     %s (alias)", display_path(target_dir .. SEP .. alias)))
                if target_is_windows then
                    print(string.format("  [check] would write     %s (alias)", display_path(target_dir .. SEP .. alias .. ".cmd")))
                end
            end
        end
        print("")
    end

    if dir_in_path(target_dir) then
        print(string.format("  [check] %s is in PATH", display_path(target_dir)))
    else
        print(string.format("  [check] %s is not in PATH", display_path(target_dir)))
    end
    print("")
    print("Nothing written (--check).")
    os.exit(0)
end

local dir_ok, dir_err = ensure_dir(target_dir)
if not dir_ok then
    io.stderr:write(string.format("deploy: cannot create target directory %s: %s\n",
        display_path(target_dir), tostring(dir_err)))
    io.stderr:write("  Choose a writable location with --dir <path>.\n")
    os.exit(1)
end

--- Writes a launcher file or aborts the deploy naming the file and the reason.
local function write_or_exit(path, data)
    local ok, err = write_file(path, data)
    if not ok then
        io.stderr:write(string.format("deploy: failed to write %s: %s\n",
            display_path(path), tostring(err)))
        os.exit(1)
    end
end

local written = 0
local deployed_names = {}
local installed_deps = {} -- dependency file names already copied during this run

for _, app in ipairs(apps_to_deploy) do
    table.insert(deployed_names, app.name)
    if app.aliases then
        for _, alias in ipairs(app.aliases) do
            table.insert(deployed_names, alias)
        end
    end
    print(string.format("[%s] %s", app.name, app.desc))

    -- 1. Copy lua script
    local ok, copy_result = copy_file(app.source_path, app.installed_lua)
    if not ok then
        io.stderr:write("deploy: failed to install " .. app.script .. ": " .. tostring(copy_result) .. "\n")
        os.exit(1)
    end
    written = written + 1
    print(string.format("  [ok] copied  %s -> %s (%s)", app.script, display_path(app.installed_lua), format_size(copy_result)))

    if app.id == 'logexplorer' then
        local test_name = 'test_ffi_log_explorer.lua'
        local test_src = script_dir .. SEP .. test_name
        if file_exists(test_src) then
            local copied, err = copy_file(test_src, target_dir .. SEP .. test_name)
            if not copied then
                error('Cannot install log explorer tests: ' .. tostring(err))
            end
            written = written + 1
        end
    end

    -- Dependencies are shared between apps: copy each once per run, always overwriting
    -- so a re-run refreshes stale copies. A missing or unwritable dependency is fatal
    -- because the installed app would fail at startup.
    for _, dep in ipairs(app.dependencies) do
        if not installed_deps[dep] then
            local dep_dst = target_dir .. SEP .. dep
            local copied, err = copy_file(script_dir .. SEP .. dep, dep_dst)
            if not copied then
                io.stderr:write(string.format("deploy: failed to install dependency %s for %s: %s\n",
                    dep, app.name, tostring(err)))
                io.stderr:write("  Ensure " .. dep .. " is in the same directory as deploy.lua.\n")
                os.exit(1)
            end
            installed_deps[dep] = true
            written = written + 1
            print(string.format("  [ok] copied  %s -> %s (dependency)", dep, display_path(dep_dst)))
        end
    end

    -- 2. Launchers (primary name + aliases)
    local names = { app.name }
    if app.aliases then
        for _, alias in ipairs(app.aliases) do
            table.insert(names, alias)
        end
    end

    for _, n in ipairs(names) do
        local is_alias = (n ~= app.name)
        local alias_tag = is_alias and " (alias)" or ""
        if target_is_windows then
            -- cmd.exe / PowerShell
            local cmd_path = target_dir .. SEP .. n .. ".cmd"
            write_or_exit(cmd_path, windows_cmd_launcher(app, luajit_path))
            written = written + 1
            print(string.format("  [ok] wrote   %s (cmd.exe / PowerShell)%s", display_path(cmd_path), alias_tag))

            -- Git Bash / MSYS shell (POSIX launcher; forward slashes when host is Windows)
            local sh_path = target_dir .. SEP .. n
            local sh_lua = host_is_windows and luajit_path:gsub("\\", "/") or luajit_path
            local sh_target = host_is_windows and app.installed_lua:gsub("\\", "/") or app.installed_lua
            write_or_exit(sh_path, posix_launcher(app, sh_lua, sh_target))
            written = written + 1
            print(string.format("  [ok] wrote   %s (Git Bash / MSYS sh)%s", display_path(sh_path), alias_tag))
        else
            local sh_path = target_dir .. SEP .. n
            write_or_exit(sh_path, posix_launcher(app, luajit_path, app.installed_lua))
            os.execute(string.format('chmod +x "%s"', sh_path))
            written = written + 1
            print(string.format("  [ok] wrote   %s (executable)%s", display_path(sh_path), alias_tag))
        end
    end
    print("")
end

-- -------------------------------------------------------------------------
-- 3. PATH advice
-- -------------------------------------------------------------------------
local try_apps = table.concat(deployed_names, "  or  ")
if dir_in_path(target_dir) then
    print(string.format("  [ok] %s is in PATH - try:  %s", display_path(target_dir), try_apps))
elseif target_is_windows then
    print(string.format("  [!]  %s is not in PATH. Add it permanently with:", display_path(target_dir)))
    print(string.format('         setx PATH "%%PATH%%;%s"', display_path(target_dir)))
    print("       (or run directly from: " .. display_path(target_dir) .. ")")
else
    print(string.format("  [!]  %s is not in PATH. Add it with:", display_path(target_dir)))
    print("         echo 'export PATH=\"$HOME/bin:$PATH\"' >> ~/.profile")
    print("       then restart your shell, or run directly from: " .. display_path(target_dir))
end

print("")
print(string.format("Deploy complete (%d files). Re-run any time to update.", written))
