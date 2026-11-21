local uv = require("uv")

local M = {}

function M.check_port_free(host, port)
    local probe = uv.new_tcp()
    local ok, err = uv.tcp_bind(probe, host, port)
    if ok then
        ok, err = uv.listen(probe, 128, function()
        end)
    end
    uv.close(probe)
    return ok ~= nil, err
end

return M
