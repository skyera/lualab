local json = require("json")
local http = require("http")
local fs = require("fs")
local path = require("path")
local NotesStore = require("./notes_store")
local net_util = require("./net_util")

local PORT = 8200
local HOST = "0.0.0.0"

-- luacheck: push ignore 113 143 (luvit globals)
local BASE_DIR = (module and module.dir) or process.cwd()

-- luacheck: pop
local PUBLIC_DIR = path.join(BASE_DIR, "public")
local store = NotesStore.new({
    { id = 1, text = "Learn Luvit HTTP servers" },
    { id = 2, text = "Build a note web app" }
})

local function send_response(res, status_code, content_type, body)
    res.statusCode = status_code
    res:setHeader("Content-Type", content_type)
    res:setHeader("Content-Length", #body)
    res:finish(body)
end

local function send_json(res, status_code, payload)
    local body = json.stringify(payload)
    send_response(res, status_code, "application/json", body)
end

local function serve_file(res, filename, content_type)
    local file_path = path.join(PUBLIC_DIR, filename)
    fs.readFile(file_path, function(err, content)
        if err then
            send_response(
                res, 500, "text/plain; charset=utf-8", tostring(err)
            )
            return
        end
        send_response(res, 200, content_type, content)
    end)
end

local function read_body(req, on_complete)
    local chunks = {}
    req:on("data", function(chunk)
        chunks[#chunks + 1] = chunk
    end)
    req:on("end", function()
        on_complete(table.concat(chunks))
    end)
end

local function create_note(req, res)
    read_body(req, function(body)
        local ok, payload = pcall(json.parse, body)
        if not ok or type(payload) ~= "table" then
            send_json(res, 400, { error = "Invalid JSON" })
            return
        end
        local note, err = store:add(payload.text)
        if not note then
            send_json(res, 400, { error = err })
            return
        end
        send_json(res, 201, note)
    end)
end

local function delete_note(res, id)
    if not store:delete(id) then
        send_json(res, 404, { error = "Note not found" })
        return
    end
    send_json(res, 200, { deleted = id })
end

local server = http.createServer(function(req, res)
    print(req.method, req.url)
    if req.method == "GET" and req.url == "/" then
        serve_file(res, "index.html", "text/html; charset=utf-8")
        return
    end
    if req.method == "GET" and req.url == "/app.js" then
        serve_file(res, "app.js", "application/javascript;charset=utf-8")
        return
    end
    if req.method == "GET" and req.url == "/api/notes" then
        send_json(res, 200, store:list())
        return
    end
    if req.method == "POST" and req.url == "/api/notes" then
        create_note(req, res)
        return
    end
    if req.method == "DELETE" then
        local id_str = req.url:match("^/api/notes/(%d+)$")
        if id_str then
            delete_note(res, tonumber(id_str))
            return
        end
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
