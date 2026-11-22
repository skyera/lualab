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
local DATA_FILE = path.join(BASE_DIR, "notes.json")
local UPLOADS_DIR = path.join(BASE_DIR, "uploads")
local MAX_UPLOAD_BYTES = 2 * 1024 * 1024
fs.mkdirSync(UPLOADS_DIR)

local store, load_err = NotesStore.load(DATA_FILE)
if not store then
    io.stderr:write("error: " .. tostring(load_err) .. "\n")
    os.exit(1)
end

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
        local note, err = store:add(payload.text, payload.image)
        if not note then
            send_json(res, 400, { error = err })
            return
        end
        local saved, save_err = store:save(DATA_FILE)
        if not saved then
            send_json(res, 500, { error = save_err })
            return
        end
        send_json(res, 201, note)
    end)
end

local function update_note(req, res, id)
    read_body(req, function(body)
        local ok, payload = pcall(json.parse, body)
        if not ok or type(payload) ~= "table" then
            send_json(res, 400, { error = "Invalid JSON" })
            return
        end
        local note, err = store:update(id, payload.text)
        if not note then
            local status = err == "Note not found" and 404 or 400
            send_json(res, status, { error = err} )
            return
        end
        local saved, save_err = store:save(DATA_FILE)
        if not saved then
            send_json(res, 500, { error = save_err} )
            return
        end
        send_json(res, 200, note)
    end)
end

local function delete_note(res, id)
    if not store:delete(id) then
        send_json(res, 404, { error = "Note not found" })
        return
    end
    local saved, save_err = store:save(DATA_FILE)
    if not saved then
        send_json(res, 500, { error = save_err })
        return
    end
    send_json(res, 200, { deleted = id })
end

local function upload_image(req, res)
    read_body(req, function(body)
        if #body == 0 or #body > MAX_UPLOAD_BYTES then
            send_json(res, 400, { error = "Invalid image size" })
            return
        end
        local filename = string.format(
            "img_%d_%d.png", os.time(), math.random(1000, 9999)
        )
        local file_path = path.join(UPLOADS_DIR, filename)
        fs.writeFile(file_path, body, function(err)
            if err then
                send_json(res, 500, { error = tostring(err) })
                return
            end
            send_json(res, 201, { url = "/uploads/" .. filename })
        end)
    end)
end

local function serve_upload(res, filename)
    local file_path = path.join(UPLOADS_DIR, filename)
    fs.readFile(file_path, function(err, content)
        if err then
            send_response(
                res, 404, "text/plain; charset=utf-8", "Not Found\n"
            )
            return
        end
        send_response(res, 200, "image/png", content)
    end)
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
    if req.method == "GET" and req.url == "/notes_util.js" then
        serve_file(
            res, "notes_util.js", "application/javascript; charset=utf-8"
        )
        return
    end
    if req.method == "GET" and req.url == "/banner.png" then
        serve_file(res, "banner.png", "image/png")
        return
    end
    if req.method == "GET" and req.url == "/api/notes" then
        send_json(res, 200, store:list())
        return
    end
    if req.method == "GET" and req.url == "/flower.js" then
        serve_file(
            res, "flower.js", "application/javascript; charset=utf-8"
        )
        return
    end
    if req.method == "POST" and req.url == "/api/upload" then
        upload_image(req, res)
        return
    end
    if req.method == "GET" then
        local name = req.url:match("^/uploads/([%w_%-]+%.png)$")
        if name then
            serve_upload(res, name)
            return
        end
    end
    if req.method == "POST" and req.url == "/api/notes" then
        create_note(req, res)
        return
    end
    if req.method == "PUT" then
        local id_str = req.url:match("^/api/notes/(%d+)$")
        if id_str then
            update_note(req, res, tonumber(id_str))
            return
        end
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
