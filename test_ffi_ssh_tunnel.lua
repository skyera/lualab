#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_ffi_ssh_tunnel.lua
-- Comprehensive test suite for ffi_ssh_tunnel.lua
--------------------------------------------------------------------------------

print("================================================================================")
print("  Running Integration & CLI Tests for ffi_ssh_tunnel.lua")
print("================================================================================")

local test_cfg = "/tmp/_test_ssh_tunnels_" .. os.time() .. ".json"
os.remove(test_cfg)

local env_prefix = string.format("SSH_TUNNEL_CONFIG='%s' ", test_cfg)
local luajit_bin = "./LuaJIT/src/luajit"

local tests = {
    {
        name = "CLI Help flag (--help)",
        cmd = luajit_bin .. " ffi_ssh_tunnel.lua --help",
        expect = "Usage:"
    },
    {
        name = "Self-test validation mode (--test)",
        cmd = luajit_bin .. " ffi_ssh_tunnel.lua --test",
        expect = "All ffi_ssh_tunnel unit tests passed successfully"
    },
    {
        name = "Empty configuration message (list with 0 profiles)",
        cmd = env_prefix .. luajit_bin .. " ffi_ssh_tunnel.lua list",
        expect = "No tunnel profiles configured yet"
    },
    {
        name = "Add custom profile via CLI (add)",
        cmd = env_prefix .. luajit_bin .. [[ ffi_ssh_tunnel.lua add '{"name":"my-db","type":"local","local_bind":"127.0.0.1","local_port":5432,"remote_host":"db.internal","remote_port":5432,"ssh_host":"gateway.net","ssh_user":"admin","proxy_jump":"jump1.corp.com"}' ]],
        expect = "Saved profile 'my-db'"
    },
    {
        name = "List configured profile (list with 1 profile)",
        cmd = env_prefix .. luajit_bin .. " ffi_ssh_tunnel.lua list",
        expect = "my-db"
    },
    {
        name = "Check occupied port 22 via FFI socket probe",
        cmd = luajit_bin .. " ffi_ssh_tunnel.lua check 22",
        expect = "is OCCUPIED"
    },
    {
        name = "Check free ephemeral port via FFI socket probe",
        cmd = luajit_bin .. " ffi_ssh_tunnel.lua check 58194",
        expect = "is AVAILABLE"
    },
    {
        name = "Release free port returns already free",
        cmd = luajit_bin .. " ffi_ssh_tunnel.lua release 58194",
        expect = "is already free"
    },
    {
        name = "Export OpenSSH ~/.ssh/config format",
        cmd = env_prefix .. luajit_bin .. " ffi_ssh_tunnel.lua export",
        expect = "Host tunnel-my-db"
    },
    {
        name = "Verify ProxyJump syntax in OpenSSH export",
        cmd = env_prefix .. luajit_bin .. " ffi_ssh_tunnel.lua export",
        expect = "ProxyJump jump1.corp.com"
    },
    {
        name = "Verify LocalForward in OpenSSH export",
        cmd = env_prefix .. luajit_bin .. " ffi_ssh_tunnel.lua export",
        expect = "LocalForward 127.0.0.1:5432 db.internal:5432"
    },
    {
        name = "Interactive TUI start and exit (tui)",
        cmd = "printf 'q' | " .. env_prefix .. luajit_bin .. " ffi_ssh_tunnel.lua tui",
        expect = "LuaJIT SSH Tunnel & ProxyJump Studio"
    },
    {
        name = "Delete profile via CLI (del)",
        cmd = env_prefix .. luajit_bin .. " ffi_ssh_tunnel.lua del my-db",
        expect = "Deleted profile 'my-db'"
    },
    {
        name = "Verify empty list after deletion",
        cmd = env_prefix .. luajit_bin .. " ffi_ssh_tunnel.lua list",
        expect = "No tunnel profiles configured yet"
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
        print("    Output:   " .. output:gsub("\n", " "):sub(1, 120))
        failed = failed + 1
    end
end

os.remove(test_cfg)

print("--------------------------------------------------------------------------------")
print(string.format("Results: %d Passed, %d Failed (Total: %d)", passed, failed, #tests))
print("================================================================================")

if failed > 0 then
    os.exit(1)
else
    os.exit(0)
end
