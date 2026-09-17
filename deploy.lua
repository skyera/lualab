#!/usr/bin/env luajit
--[[
    deploy.lua
    Installs lualab tools (pix.lua, yt.lua) plus thin launchers, so they can be
    started by simply typing `pix` or `yt`:

      Linux / macOS : ~/bin/<app>.lua  + ~/bin/<app>      (POSIX sh, made executable)
      Windows       : C:\app\bin\<app>.lua + <app>.cmd    (cmd.exe / PowerShell)
                      C:\app\bin\<app>     (Git Bash / MSYS sh)

    Usage:
      luajit deploy.lua                     Install all tools for the current OS
      luajit deploy.lua --app <pix|yt|all>  Select specific tool (default: all)
      luajit deploy.lua --dir <path>        Install into a custom directory
      luajit deploy.lua --os windows        Generate the Windows layout (e.g. from Linux/CI)
      luajit deploy.lua --check             Report only, write nothing
      luajit deploy.lua -h                  Show usage

    The launcher prefers the `luajit` found on PATH ($<APP>_LUAJIT overrides it) and falls back to the
    absolute luajit that ran this deploy, so launchers keep working when luajit is not on PATH.
]]

local ffi = require("ffi")

-- =========================================================================
-- 1. Options & Registry
-- =========================================================================
local APPS = {
    pix = {
        id = "pix",
        name = "pix",
        script = "pix.lua",
        desc = "Terminal Directory Image Viewer",
        env_var = "PIX_LUAJIT",
    },
    yt = {
        id = "yt",
        name = "yt",
        script = "yt.lua",
        desc = "YouTube & YouTube Music Terminal Player",
        env_var = "YT_LUAJIT",
    },
}

local opts = {
    app = "all",
    dir = nil,
    os = nil,
    check = false,
}

local function print_usage()
    print("lualab deploy — Cross-Platform Tools Deployer (LuaJIT FFI)")
    print("Usage:")
    print("  luajit deploy.lua [--app all|pix|yt] [--dir <path>] [--os linux|windows] [--check]")
    print("")
    print("  --app <name>    App to deploy: all (default), pix, or yt")
    print("  --dir <path>    Target directory (default: C:\\app\\bin on Windows, ~/bin elsewhere)")
    print("  --os <name>     Force the target layout: linux (POSIX) or windows")
    print("  --check         Show what would be installed without writing anything")
end

do
    local i = 1
    local argv = arg or {}
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

if opts.app ~= "all" and opts.app ~= "pix" and opts.app ~= "yt" then
    io.stderr:write("deploy: unknown --app '" .. tostring(opts.app) .. "' (use all, pix, or yt)\n")
    os.exit(2)
end

local target_os = (opts.os or (ffi.os == "Windows" and "windows") or "linux"):lower()
if target_os ~= "windows" and target_os ~= "linux" and target_os ~= "posix" then
    io.stderr:write("deploy: unsupported --os '" .. target_os .. "' (use linux or windows)\n")
    os.exit(2)
end

-- Two distinct notions: this filesystem (host) uses / or \, while the deployed layout (target)
-- decides which launchers to write and which PATH syntax to advise.
local host_is_windows = (ffi.os == "Windows")
local target_is_windows = (target_os == "windows")
local SEP = host_is_windows and "\\" or "/"

-- =========================================================================
-- 2. Filesystem & path helpers
-- =========================================================================
local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
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

local function copy_file(src, dst)
    local in_f = io.open(src, "rb")
    if not in_f then return false, "cannot read " .. src end
    local out_f = io.open(dst, "wb")
    if not out_f then
        in_f:close()
        return false, "cannot write " .. dst
    end

    local total = 0
    while true do
        local chunk = in_f:read(64 * 1024)
        if not chunk then break end
        out_f:write(chunk)
        total = total + #chunk
    end
    in_f:close()
    out_f:close()
    return true, total
end

local function write_file(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
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
    local cwd = os.getenv("PWD") or command_output(host_is_windows and "cd" or "pwd")
    if not cwd or cwd == "" then cwd = "." end
    return cwd
end

local function normalize_dir(path)
    if not path or path == "" then return path end
    path = path:gsub("^%s+", ""):gsub("%s+$", "")
    path = path:gsub('"', ""):gsub("'", "")
    if host_is_windows then
        path = path:gsub("/", "\\")
        path = path:gsub("\\+$", "")
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
    local self_path = (arg and arg[0]) or "deploy.lua"
    local dir = self_path:match("^(.*)[/\\][^/\\]*$")

    if dir and dir ~= "" then
        if is_absolute(dir) then return normalize_dir(dir) end
        return normalize_dir(get_cwd() .. SEP .. dir)
    end
    return normalize_dir(get_cwd())
end

-- Absolute path of the luajit that is running this deploy (bare names resolved via PATH)
local function resolve_luajit()
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

local function ensure_dir(path)
    if host_is_windows then
        os.execute(string.format('if not exist "%s" mkdir "%s"', path, path))
    else
        os.execute(string.format('mkdir -p "%s" 2>/dev/null', path))
    end
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

-- cmd.exe needs CRLF line endings; script is located through %~dp0 so any target dir works.
local function windows_cmd_launcher(app, luajit_path)
    return table.concat({
        "@echo off",
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
        '"%LUAJIT%" "%~dp0' .. app.script .. '" %*',
        "",
    }, "\r\n")
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
    table.insert(apps_to_deploy, APPS.pix)
    table.insert(apps_to_deploy, APPS.yt)
elseif opts.app == "pix" then
    table.insert(apps_to_deploy, APPS.pix)
elseif opts.app == "yt" then
    table.insert(apps_to_deploy, APPS.yt)
end

print("lualab deploy — Cross-Platform Suite (LuaJIT FFI)")
print("  Target : " .. target_dir .. "   (" .. kind .. ")")
print("  Runtime: " .. luajit_path)
print("")

for _, app in ipairs(apps_to_deploy) do
    app.source_path = script_dir .. SEP .. app.script
    app.installed_lua = target_dir .. SEP .. app.script
    if not file_exists(app.source_path) then
        io.stderr:write("deploy: " .. app.script .. " not found next to deploy.lua (" .. app.source_path .. ")\n")
        os.exit(1)
    end
end

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
        print(string.format("  [check] would write     %s", display_path(target_dir .. SEP .. app.name)))
        if target_is_windows then
            print(string.format("  [check] would write     %s", display_path(target_dir .. SEP .. app.name .. ".cmd")))
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

ensure_dir(target_dir)

local written = 0
local deployed_names = {}

for _, app in ipairs(apps_to_deploy) do
    table.insert(deployed_names, app.name)
    print(string.format("[%s] %s", app.name, app.desc))

    -- 1. Copy lua script
    local ok, copy_result = copy_file(app.source_path, app.installed_lua)
    if not ok then
        io.stderr:write("deploy: failed to install " .. app.script .. ": " .. tostring(copy_result) .. "\n")
        os.exit(1)
    end
    written = written + 1
    print(string.format("  [ok] copied  %s -> %s (%s)", app.script, display_path(app.installed_lua), format_size(copy_result)))

    -- 2. Launchers
    if target_is_windows then
        -- cmd.exe / PowerShell
        local cmd_path = target_dir .. SEP .. app.name .. ".cmd"
        if not write_file(cmd_path, windows_cmd_launcher(app, luajit_path)) then
            io.stderr:write("deploy: failed to write " .. display_path(cmd_path) .. "\n")
            os.exit(1)
        end
        written = written + 1
        print(string.format("  [ok] wrote   %s (cmd.exe / PowerShell)", display_path(cmd_path)))

        -- Git Bash / MSYS shell (POSIX launcher; forward slashes when host is Windows)
        local sh_path = target_dir .. SEP .. app.name
        local sh_lua = host_is_windows and luajit_path:gsub("\\", "/") or luajit_path
        local sh_target = host_is_windows and app.installed_lua:gsub("\\", "/") or app.installed_lua
        if not write_file(sh_path, posix_launcher(app, sh_lua, sh_target)) then
            io.stderr:write("deploy: failed to write " .. display_path(sh_path) .. "\n")
            os.exit(1)
        end
        written = written + 1
        print(string.format("  [ok] wrote   %s (Git Bash / MSYS sh)", display_path(sh_path)))
    else
        local sh_path = target_dir .. SEP .. app.name
        if not write_file(sh_path, posix_launcher(app, luajit_path, app.installed_lua)) then
            io.stderr:write("deploy: failed to write " .. display_path(sh_path) .. "\n")
            os.exit(1)
        end
        os.execute(string.format('chmod +x "%s"', sh_path))
        written = written + 1
        print(string.format("  [ok] wrote   %s (executable)", display_path(sh_path)))
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
