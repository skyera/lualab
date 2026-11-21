local http = require("http")
local fs = require("fs")
local path = require("path")
local net_util = require("./net_util")

local PORT = 8200
local HOST = "0.0.0.0"

-- luacheck: push ignore 113 143 (luvit globals)
local BASE_DIR = (module and module.dir) or process.cwd()

-- luacheck: pop
local PUBLIC_DIR = path.join(BASE_DIR, "public")

local function send_response(res, status_code, content_type, body)
    res.statusCode = status_code
    res:setHeader("Content-Type", content_type)
    res:setHeader("Content-Length", #body)
    res:finish(body)
end

local function serve_index(res)
    local file_path = path.join(PUBLIC_DIR, "index.html")
    fs.readFile(file_path, function(err, content)
        if err then
            send_response(res, 500, "text/plain; charset=utf-8", tostring(err))
            return
        end
        send_response(res, 200, "text/html; charset=utf-8", content)
    end)
end

local server = http.createServer(function(req, res)
    print(req.method, req.url)
    if req.method == "GET" and req.url == "/" then
        serve_index(res)
        return
    end
    send_response(res, 404, "text/plain; charset=utf-8", "Not Found\n")
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
