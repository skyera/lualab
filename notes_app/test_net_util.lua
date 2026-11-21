local uv = require("uv")
local net_util = require("./net_util")

local function open_blocker()
    local socket = uv.new_tcp()
    assert(uv.tcp_bind(socket, "127.0.0.1", 0))
    assert(uv.listen(socket, 128, function()
    end))
    return socket, uv.tcp_getsockname(socket).port
end

local function test_free_port(port)
    net_util.check_port_free("127.0.0.1", port, function()
        print("PASS free port")
        print("ALL PASSED")
    end, function(err)
        error("expected free port, got: " .. tostring(err))
    end)
end

local function test_busy_port()
    local blocker, port = open_blocker()
    net_util.check_port_free("127.0.0.1", port, function()
        error("expected busy port to fail")
    end, function(err)
        assert(tostring(err):find("EADDRINUSE", 1, true))
        print("PASS BUSY port")
        uv.close(blocker, function()
            test_free_port(port)
        end)
    end)
end

test_busy_port()
