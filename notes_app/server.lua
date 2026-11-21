local http = require("http")
local net_util = require("./net_util")

local PORT = 8200
local HOST = "0.0.0.0"

local server = http.createServer(function(req, res)
    print(req.method, req.url)
    local body = "Hello from Luvit!\n"
    res.statusCode = 200
    res:setHeader("Content-Type", "text/plain; charset=utf-8")
    res:setHeader("Content-Length", #body)
    res:finish(body)
end)

local is_free, err = net_util.check_port_free(HOST, PORT)
if not is_free then
    io.stderr:write(string.format(
        "error: cannot listen on %s:%d (%s)\n",
        HOST,
        PORT,
        tostring(err)
    ))
    os.exit(1)
end

server:listen(PORT, HOST, function()
    print(string.format(
        "Notes server running at http://%s:%d/",
        HOST,
        PORT
    ))
end)
