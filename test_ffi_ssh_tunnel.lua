#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_ffi_ssh_tunnel.lua
-- Comprehensive test suite for ffi_ssh_tunnel.lua
--------------------------------------------------------------------------------

print("================================================================================")
print("  Running Integration & CLI Tests for ffi_ssh_tunnel.lua")
print("================================================================================")

local tests = {
    {
        name = "CLI Help flag (--help)",
        cmd = "./LuaJIT/src/luajit ffi_ssh_tunnel.lua --help",
        expect = "Usage:"
    },
    {
        name = "Self-test validation mode (--test)",
        cmd = "./LuaJIT/src/luajit ffi_ssh_tunnel.lua --test",
        expect = "All ffi_ssh_tunnel unit tests passed successfully"
    },
    {
        name = "List configured profiles (list)",
        cmd = "./LuaJIT/src/luajit ffi_ssh_tunnel.lua list",
        expect = "prod-postgres"
    },
    {
        name = "Verify Dynamic SOCKS5 profile listed",
        cmd = "./LuaJIT/src/luajit ffi_ssh_tunnel.lua list",
        expect = "dev-socks5"
    },
    {
        name = "Check occupied port 22 via FFI socket probe",
        cmd = "./LuaJIT/src/luajit ffi_ssh_tunnel.lua check 22",
        expect = "is OCCUPIED"
    },
    {
        name = "Check free ephemeral port via FFI socket probe",
        cmd = "./LuaJIT/src/luajit ffi_ssh_tunnel.lua check 58194",
        expect = "is AVAILABLE"
    },
    {
        name = "Export OpenSSH ~/.ssh/config format",
        cmd = "./LuaJIT/src/luajit ffi_ssh_tunnel.lua export",
        expect = "Host tunnel-prod-postgres"
    },
    {
        name = "Verify ProxyJump syntax in OpenSSH export",
        cmd = "./LuaJIT/src/luajit ffi_ssh_tunnel.lua export",
        expect = "ProxyJump bastion1.corp.com,jump2.vpc.corp.com"
    },
    {
        name = "Verify LocalForward in OpenSSH export",
        cmd = "./LuaJIT/src/luajit ffi_ssh_tunnel.lua export",
        expect = "LocalForward 127.0.0.1:5432 db-prod.internal.net:5432"
    },
    {
        name = "Verify DynamicForward in OpenSSH export",
        cmd = "./LuaJIT/src/luajit ffi_ssh_tunnel.lua export",
        expect = "DynamicForward 127.0.0.1:1080"
    },
    {
        name = "Interactive TUI start and exit (tui)",
        cmd = "printf 'q' | ./LuaJIT/src/luajit ffi_ssh_tunnel.lua tui",
        expect = "LuaJIT SSH Tunnel & ProxyJump Studio"
    }
}

local passed = 0
local failed = 0

for i, t in ipairs(tests) do
    io.write(string.format("  [%02d/%02d] %-55s ... ", i, #tests, t.name))
    local pipe = io.popen(t.cmd .. " 2>&1")
    local output = pipe and pipe:read("*a") or ""
    local ok = pipe and pipe:close()

    if output:find(t.expect, 1, true) then
        print("\27[1;32mPASS\27[0m")
        passed = passed + 1
    else
        print("\27[1;31mFAIL\27[0m")
        print("    Command:  " .. t.cmd)
        print("    Expected: " .. t.expect)
        print("    Output:   " .. output:gsub("\n", " "):sub(1, 100))
        failed = failed + 1
    end
end

print("--------------------------------------------------------------------------------")
print(string.format("Results: %d Passed, %d Failed (Total: %d)", passed, failed, #tests))
print("================================================================================")

if failed > 0 then
    os.exit(1)
else
    os.exit(0)
end
