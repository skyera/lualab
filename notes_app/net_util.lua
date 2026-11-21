local uv = require("uv")

local M = {}

function M.check_port_free(host, port, on_free, on_error)
    local probe = uv.new_tcp()
    local ok, err = uv.tcp_bind(probe, host, port)
    if ok then
        ok, err = uv.listen(probe, 128, function()
        end)
    end
    uv.close(probe, function()
        if ok then
            on_free()
        else
            on_error(err)
        end
    end)
end

return M
