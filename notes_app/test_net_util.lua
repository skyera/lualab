local uv = require("uv")
local net_util = require("./net_util")

local function open_blocker()
    local socket = uv.new_tcp()
    assert(uv.tcp_bind(socket, "127.0.0.1", 0))
    assert(uv.listen(socket, 128, function()
    end))
    return socket, uv.tcp_getsockname(socket).port
end

local function test_free_port()
    local temp, port = open_blocker()
    uv.close(temp)
    local is_free, err = net_util.check_port_free("127.0.0.1", port)
    assert(is_free, tostring(err))
    print("PASS free port")
end

local function test_busy_port()
    local blocker, port = open_blocker()
    local is_free, err = net_util.check_port_free("127.0.0.1", port)
    uv.close(blocker)
    assert(not is_free)
    assert(tostring(err):find("EADDRINUSE", 1, true))
    print("PASS busy port")
end

test_free_port()
test_busy_port()
print("ALL PASSED")
