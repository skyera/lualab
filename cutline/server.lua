-- =============================================================================
-- LuaJIT Cutline Analyzer - Luvit HTTP Server
--
-- Serves the web UI and provides FFI-backed RGBA image storage, bilinear
-- cutline intensity sampling, line statistics, and CSV export.
-- =============================================================================

local http = require("http")
local fs = require("fs")
local path = require("path")
local json = require("json")
local url = require("url")
local querystring = require("querystring")
local ffi = require("ffi")
local uv = require("uv")

-- =============================================================================
-- Constants
-- =============================================================================

local DEFAULT_HOST = "127.0.0.1"
local PUBLIC_HOST = "0.0.0.0"
local DEFAULT_PORT = 8100
local MIN_PORT = 1
local MAX_PORT = 65535
local PRIVILEGED_PORT_LIMIT = 1024
local LISTEN_BACKLOG = 128
local EXIT_LISTEN_FAILED = 1
local EXIT_USAGE = 2

local USAGE = "usage: luvit server.lua [--public | --host ADDR] [--port N]"
local HELP_TEXT = USAGE .. [[


  --public     listen on all interfaces (0.0.0.0) so other computers
               can connect; there is no authentication
  --host ADDR  listen on one IP address of this computer
               (default 127.0.0.1, local only)
  --port N     TCP port from 1 to 65535 (default 8100)
  --help       show this help

The PORT environment variable sets the default port; --port wins.]]

-- luacheck: push ignore 113 143 (luvit globals)
local BASE_DIR = (module and module.dir) or process.cwd()
-- luacheck: pop
local PUBLIC_DIR = path.join(BASE_DIR, "public")
local MIME_HTML = "text/html; charset=utf-8"
local MIME_JS = "application/javascript; charset=utf-8"

local RGBA_CHANNELS = 4
local MAX_IMAGE_DIM = 16384
local MAX_UPLOAD_BYTES = 64 * 1024 * 1024
local MAX_JSON_BYTES = 64 * 1024
local MAX_STORED_IMAGES = 16
local MIN_SAMPLES = 2
local MAX_SAMPLES = 4096
local MAX_INTENSITY = 255.0

local LUMA_WEIGHT_R = 0.2126
local LUMA_WEIGHT_G = 0.7152
local LUMA_WEIGHT_B = 0.0722

-- =============================================================================
-- State
-- =============================================================================

local images = {}
local image_order = {}
local next_image_id = 1

-- =============================================================================
-- Helpers
-- =============================================================================

--- Return true when `value` is a finite number (not nil, NaN, or +/-inf).
local function is_finite_number(value)
    return type(value) == "number"
        and value == value
        and math.abs(value) < math.huge
end

--- Return true when `value` is a valid image width or height.
local function is_valid_dimension(value)
    return is_finite_number(value)
        and value == math.floor(value)
        and value >= 1
        and value <= MAX_IMAGE_DIM
end

--- Clamp `value` into the inclusive range [`low`, `high`].
local function clamp(value, low, high)
    if value ~= value or value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

--- Round `value` to two decimal places.
local function round_two(value)
    return math.floor(value * 100 + 0.5) / 100
end

--- Return the active LuaJIT or Lua runtime version string.
local function get_runtime_version()
    if jit and jit.version then
        return jit.version
    end
    return _VERSION
end

--- Send a JSON response with HTTP `status_code` and `payload` table.
local function send_json(res, status_code, payload)
    local body = json.stringify(payload)
    res.statusCode = status_code
    res:setHeader("Content-Type", "application/json")
    res:setHeader("Content-Length", #body)
    res:finish(body)
end

--- Send a plain-text response with HTTP `status_code` and `message`.
local function send_text(res, status_code, message)
    res.statusCode = status_code
    res:setHeader("Content-Type", "text/plain; charset=utf-8")
    res:setHeader("Content-Length", #message)
    res:finish(message)
end

--- Read an HTTP request body up to `max_bytes` and invoke `on_complete(body)`.
--- Errors inside `on_complete` are caught and reported as HTTP 500.
local function read_request_body(req, res, max_bytes, on_complete)
    local chunks = {}
    local total_bytes = 0
    local aborted = false

    req:on("data", function(chunk)
        if aborted then
            return
        end
        total_bytes = total_bytes + #chunk
        if total_bytes > max_bytes then
            aborted = true
            chunks = nil
            local msg = string.format(
                "Request body exceeds limit of %d bytes",
                max_bytes
            )
            send_json(res, 413, { error = msg })
            return
        end
        chunks[#chunks + 1] = chunk
    end)

    req:on("error", function(err)
        if aborted then
            return
        end
        aborted = true
        chunks = nil
        io.stderr:write("Request stream error: " .. tostring(err) .. "\n")
    end)

    req:on("end", function()
        if aborted then
            return
        end
        local body = table.concat(chunks)
        chunks = nil
        local ok, err = pcall(on_complete, body)
        if not ok then
            io.stderr:write("Request error: " .. tostring(err) .. "\n")
            send_json(res, 500, { error = "Internal server error" })
        end
    end)
end

-- =============================================================================
-- Cutline Sampling & Statistics
-- =============================================================================

--- Compute the 4 RGBA byte offsets and bilinear weights for (`x`, `y`).
local function compute_bilinear_tap(w, h, x, y)
    local cx = clamp(x, 0, w - 1)
    local cy = clamp(y, 0, h - 1)
    local x0 = math.floor(cx)
    local y0 = math.floor(cy)
    local x1 = math.min(x0 + 1, w - 1)
    local y1 = math.min(y0 + 1, h - 1)
    local fx = cx - x0
    local fy = cy - y0

    local offsets = {
        (y0 * w + x0) * RGBA_CHANNELS,
        (y0 * w + x1) * RGBA_CHANNELS,
        (y1 * w + x0) * RGBA_CHANNELS,
        (y1 * w + x1) * RGBA_CHANNELS
    }
    local weights = {
        (1 - fx) * (1 - fy),
        fx * (1 - fy),
        (1 - fx) * fy,
        fx * fy
    }
    return offsets, weights
end

--- Blend one color `channel` (0=R, 1=G, 2=B) across 4 bilinear taps.
local function blend_channel(buffer, offsets, weights, channel)
    return buffer[offsets[1] + channel] * weights[1]
        + buffer[offsets[2] + channel] * weights[2]
        + buffer[offsets[3] + channel] * weights[3]
        + buffer[offsets[4] + channel] * weights[4]
end

--- Sample RGBA pixel values from FFI `buffer` (`w` by `h`) at (`x`, `y`).
--- Returns `r, g, b, luminance`.
local function sample_bilinear(buffer, w, h, x, y)
    local offsets, weights = compute_bilinear_tap(w, h, x, y)
    local red = blend_channel(buffer, offsets, weights, 0)
    local green = blend_channel(buffer, offsets, weights, 1)
    local blue = blend_channel(buffer, offsets, weights, 2)
    local luma = LUMA_WEIGHT_R * red
        + LUMA_WEIGHT_G * green
        + LUMA_WEIGHT_B * blue
    return red, green, blue, luma
end

--- Compute min, max, mean, and standard deviation of numeric `values`.
local function summarize_series(values)
    local min_val = MAX_INTENSITY
    local max_val = 0.0
    local sum = 0.0
    local sum_sq = 0.0
    for i = 1, #values do
        local val = values[i]
        if val < min_val then
            min_val = val
        end
        if val > max_val then
            max_val = val
        end
        sum = sum + val
        sum_sq = sum_sq + val * val
    end
    local mean = sum / #values
    local variance = math.max(0, (sum_sq / #values) - (mean * mean))
    return min_val, max_val, mean, math.sqrt(variance)
end

--- Build the summary statistics table for `luma_values` along `segment`.
local function build_cutline_stats(segment, length, luma_values)
    local min_val, max_val, mean, stddev = summarize_series(luma_values)
    return {
        length = round_two(length),
        samples = #luma_values,
        min = round_two(min_val),
        max = round_two(max_val),
        mean = round_two(mean),
        stddev = round_two(stddev),
        x1 = round_two(segment.x1),
        y1 = round_two(segment.y1),
        x2 = round_two(segment.x2),
        y2 = round_two(segment.y2)
    }
end

--- Sample `count` evenly spaced points along `segment` on `image`.
local function sample_cutline_points(image, segment, length, count)
    local dx = segment.x2 - segment.x1
    local dy = segment.y2 - segment.y1
    local series = { distance = {}, r = {}, g = {}, b = {}, luma = {} }
    for i = 0, count - 1 do
        local ratio = i / (count - 1)
        local x = segment.x1 + dx * ratio
        local y = segment.y1 + dy * ratio
        local r, g, b, luma = sample_bilinear(
            image.buffer, image.width, image.height, x, y
        )
        local index = i + 1
        series.distance[index] = round_two(length * ratio)
        series.r[index] = round_two(r)
        series.g[index] = round_two(g)
        series.b[index] = round_two(b)
        series.luma[index] = round_two(luma)
    end
    return series
end

--- Compute the cutline profile and statistics for `image` along `segment`.
local function compute_cutline(image, segment)
    local dx = segment.x2 - segment.x1
    local dy = segment.y2 - segment.y1
    local length = math.sqrt(dx * dx + dy * dy)
    local default_count = math.max(MIN_SAMPLES, math.floor(length) + 1)
    local requested = segment.samples and math.floor(segment.samples)
    local count = clamp(requested or default_count, MIN_SAMPLES, MAX_SAMPLES)

    local result = sample_cutline_points(image, segment, length, count)
    result.stats = build_cutline_stats(segment, length, result.luma)
    return result
end

--- Parse optional finite numeric field `name` from `params`.
--- Returns `value`, `default` when absent, or `nil, err` when invalid.
local function parse_optional_number(params, name, default)
    local raw = params[name]
    if raw == nil or raw == "" then
        return default
    end
    local num = tonumber(raw)
    if not is_finite_number(num) then
        return nil, string.format("Invalid numeric parameter: %s", name)
    end
    return num
end

--- Parse cutline segment coordinates from `params` with defaults for `image`.
--- Returns `segment` table, or `nil, err` for non-numeric or NaN parameters.
local function parse_segment_params(params, image)
    local x1, err1 = parse_optional_number(params, "x1", 0)
    if err1 then
        return nil, err1
    end
    local y1, err2 = parse_optional_number(params, "y1", 0)
    if err2 then
        return nil, err2
    end
    local x2, err3 = parse_optional_number(params, "x2", image.width - 1)
    if err3 then
        return nil, err3
    end
    local y2, err4 = parse_optional_number(params, "y2", image.height - 1)
    if err4 then
        return nil, err4
    end
    local samples, err5 = parse_optional_number(params, "samples", nil)
    if err5 then
        return nil, err5
    end
    return { x1 = x1, y1 = y1, x2 = x2, y2 = y2, samples = samples }
end

--- Format a cutline `result` table as a CSV string.
local function format_cutline_csv(result)
    local lines = { "index,distance_px,r,g,b,luminance" }
    for i = 1, #result.distance do
        lines[#lines + 1] = string.format(
            "%d,%.2f,%.2f,%.2f,%.2f,%.2f",
            i - 1,
            result.distance[i],
            result.r[i],
            result.g[i],
            result.b[i],
            result.luma[i]
        )
    end
    return table.concat(lines, "\n") .. "\n"
end

-- =============================================================================
-- Route Handlers
-- =============================================================================

--- Serve the health check endpoint.
local function serve_health(_, res)
    send_json(res, 200, {
        status = "ok",
        runtime = get_runtime_version()
    })
end

--- Evict oldest stored images so memory stays bounded by `MAX_STORED_IMAGES`.
local function evict_oldest_images()
    while #image_order >= MAX_STORED_IMAGES do
        local oldest_id = table.remove(image_order, 1)
        images[oldest_id] = nil
    end
end

--- Validate and store raw RGBA `body` in an FFI buffer; returns `id` or
--- `nil, err`.
local function save_rgba_buffer(body, w, h)
    local expected_bytes = w * h * RGBA_CHANNELS
    if #body ~= expected_bytes then
        return nil, string.format(
            "Expected %d RGBA bytes, got %d",
            expected_bytes,
            #body
        )
    end

    evict_oldest_images()
    local buffer = ffi.new("uint8_t[?]", expected_bytes)
    ffi.copy(buffer, body, expected_bytes)

    local image_id = tostring(next_image_id)
    next_image_id = next_image_id + 1
    images[image_id] = { width = w, height = h, buffer = buffer }
    image_order[#image_order + 1] = image_id
    return image_id
end

--- Store a raw RGBA image buffer uploaded from the browser canvas.
local function store_uploaded_image(req, res)
    local w = tonumber(req.headers["x-image-width"])
    local h = tonumber(req.headers["x-image-height"])
    if not is_valid_dimension(w) or not is_valid_dimension(h) then
        local msg = "Missing or invalid X-Image-Width / X-Image-Height"
        send_json(res, 400, { error = msg })
        return
    end
    if w * h * RGBA_CHANNELS > MAX_UPLOAD_BYTES then
        local msg = string.format(
            "Image exceeds upload limit of %d bytes",
            MAX_UPLOAD_BYTES
        )
        send_json(res, 413, { error = msg })
        return
    end

    read_request_body(req, res, MAX_UPLOAD_BYTES, function(body)
        local image_id, err = save_rgba_buffer(body, w, h)
        if not image_id then
            send_json(res, 400, { error = err })
            return
        end
        send_json(res, 200, { image_id = image_id, width = w, height = h })
    end)
end

--- Compute and return cutline profile JSON for the requested image segment.
local function serve_cutline_profile(req, res)
    read_request_body(req, res, MAX_JSON_BYTES, function(body)
        local ok, payload = pcall(json.parse, body)
        if not ok or type(payload) ~= "table" then
            send_json(res, 400, { error = "Invalid JSON body" })
            return
        end
        local image = images[tostring(payload.image_id)]
        if not image then
            send_json(res, 404, { error = "Image not found" })
            return
        end
        local segment, seg_err = parse_segment_params(payload, image)
        if not segment then
            send_json(res, 400, { error = seg_err })
            return
        end
        send_json(res, 200, compute_cutline(image, segment))
    end)
end

--- Export the cutline profile as a downloadable CSV file.
local function export_cutline_csv(_, res, parsed_url)
    local query = querystring.parse(parsed_url.query or "")
    local image = images[tostring(query.image_id)]
    if not image then
        send_json(res, 404, { error = "Image not found" })
        return
    end

    local segment, seg_err = parse_segment_params(query, image)
    if not segment then
        send_json(res, 400, { error = seg_err })
        return
    end
    local csv = format_cutline_csv(compute_cutline(image, segment))
    res.statusCode = 200
    res:setHeader("Content-Type", "text/csv; charset=utf-8")
    res:setHeader(
        "Content-Disposition",
        'attachment; filename="cutline_profile.csv"'
    )
    res:setHeader("Content-Length", #csv)
    res:finish(csv)
end

--- Serve a static asset file from `PUBLIC_DIR` with `content_type`.
local function serve_static_file(res, filename, content_type)
    local file_path = path.join(PUBLIC_DIR, filename)
    fs.readFile(file_path, function(err, content)
        if err then
            local msg = string.format(
                "Failed to load %s: %s",
                file_path,
                tostring(err)
            )
            send_text(res, 500, msg)
            return
        end
        res.statusCode = 200
        res:setHeader("Content-Type", content_type)
        res:setHeader("Content-Length", #content)
        res:finish(content)
    end)
end

local STATIC_ASSETS = {
    ["/"] = { file = "index.html", mime = MIME_HTML },
    ["/index.html"] = { file = "index.html", mime = MIME_HTML },
    ["/app.js"] = { file = "app.js", mime = MIME_JS },
    ["/plot.js"] = { file = "plot.js", mime = MIME_JS },
    ["/colormaps.js"] = { file = "colormaps.js", mime = MIME_JS },
    ["/theme.js"] = { file = "theme.js", mime = MIME_JS }
}

--- Serve a whitelisted static file from `STATIC_ASSETS`.
local function serve_static_route(_, res, parsed_url)
    local asset = STATIC_ASSETS[parsed_url.pathname or "/"]
    serve_static_file(res, asset.file, asset.mime)
end

local ROUTES = {
    ["GET /"] = serve_static_route,
    ["GET /index.html"] = serve_static_route,
    ["GET /app.js"] = serve_static_route,
    ["GET /plot.js"] = serve_static_route,
    ["GET /colormaps.js"] = serve_static_route,
    ["GET /theme.js"] = serve_static_route,
    ["GET /api/health"] = serve_health,
    ["POST /api/image"] = store_uploaded_image,
    ["POST /api/cutline"] = serve_cutline_profile,
    ["GET /api/export"] = export_cutline_csv
}

-- =============================================================================
-- Command-Line Options
-- =============================================================================

--- Convert `text` to a TCP port number.
--- Returns the port, or nil and an error that quotes `text`.
local function parse_port(text)
    local port = tonumber(text)
    local is_valid = port ~= nil
        and port == math.floor(port)
        and port >= MIN_PORT
        and port <= MAX_PORT
    if not is_valid then
        return nil, string.format(
            'invalid port "%s" (expected an integer from %d to %d)',
            tostring(text),
            MIN_PORT,
            MAX_PORT
        )
    end
    return port
end

--- Return `value` when it can be the argument of `flag`.
--- Returns nil and an error when it is missing or is another flag.
local function require_option_value(flag, value)
    if value == nil or value:sub(1, 1) == "-" then
        return nil, "missing value for " .. flag
    end
    return value
end

local function select_public_host(options)
    options.host = PUBLIC_HOST
    return 0
end

local function select_host(options, value)
    local host, err = require_option_value("--host", value)
    if not host then
        return nil, err
    end
    options.host = host
    return 1
end

local function select_port(options, value)
    local text, err = require_option_value("--port", value)
    if not text then
        return nil, err
    end
    local port, port_err = parse_port(text)
    if not port then
        return nil, port_err
    end
    options.port = port
    return 1
end

local function select_help(options)
    options.show_help = true
    return 0
end

--- Option handlers: each updates `options` from the flag and the next
--- argument, and returns how many extra arguments it used, or nil, err.
local OPTION_HANDLERS = {
    ["--public"] = select_public_host,
    ["--host"] = select_host,
    ["--port"] = select_port,
    ["--help"] = select_help,
    ["-h"] = select_help
}

--- Build the listen options from the defaults, `port_env` (the PORT
--- environment variable) and `argv` (arguments after the script path).
--- Command-line flags win over PORT.
--- Returns { host, port, show_help }, or nil, err for invalid input.
local function parse_options(argv, port_env)
    local options = { host = DEFAULT_HOST, port = DEFAULT_PORT }
    if port_env and port_env ~= "" then
        local port, err = parse_port(port_env)
        if not port then
            return nil, "PORT environment variable: " .. err
        end
        options.port = port
    end

    local index = 1
    while index <= #argv do
        local flag = argv[index]
        local handler = OPTION_HANDLERS[flag]
        if not handler then
            return nil, string.format('unknown option "%s"', flag)
        end
        local extra_count, err = handler(options, argv[index + 1])
        if not extra_count then
            return nil, err
        end
        index = index + 1 + extra_count
    end
    return options
end

--- Return the command-line arguments that follow the script path.
local function get_script_arguments()
    -- luvit keeps argv in the global `args`; args[1] is the script.
    local luvit_args = args -- luacheck: ignore 113 (luvit global)
    local script_args = {}
    for i = 2, #luvit_args do
        script_args[#script_args + 1] = luvit_args[i]
    end
    return script_args
end

-- =============================================================================
-- Listening
-- =============================================================================

--- Bind `probe` to `host`:`port` and start listening on it.
--- Returns true, or nil and the uv error message. An address that is not
--- an IP literal makes uv raise, so the bind is protected.
local function bind_and_listen(probe, host, port)
    local ok, bind_result, bind_err = pcall(uv.tcp_bind, probe, host, port)
    if not ok then
        local message = tostring(bind_result):gsub("^.-:%d+: ", "")
        return nil, message
    end
    if not bind_result then
        return nil, bind_err
    end
    local listened, listen_err = uv.listen(probe, LISTEN_BACKLOG, function()
    end)
    if not listened then
        return nil, listen_err
    end
    return true
end

--- Check that `host`:`port` can be listened on, using a throwaway socket.
--- luvit's Server:listen ignores bind and listen errors, so this is the
--- only way to report them. Calls `on_ready()` after the probe socket has
--- closed, so the real listen can reuse the port (Windows sets no
--- SO_REUSEADDR), or `on_error(message)`.
local function probe_listen_address(host, port, on_ready, on_error)
    local probe = uv.new_tcp()
    local ok, err = bind_and_listen(probe, host, port)
    uv.close(probe, function()
        if ok then
            on_ready()
        else
            on_error(err)
        end
    end)
end

--- Return a recovery hint for listen error `message` on `options`.
local function get_listen_failure_hint(message, options)
    if message:find("EADDRINUSE", 1, true) then
        local next_port = options.port + 1
        if next_port > MAX_PORT then
            next_port = DEFAULT_PORT
        end
        return string.format(
            "Stop the other process or choose another port: --port %d",
            next_port
        )
    end
    if message:find("EACCES", 1, true)
        and options.port < PRIVILEGED_PORT_LIMIT then
        return string.format(
            "Ports below %d need root; choose another: --port %d",
            PRIVILEGED_PORT_LIMIT,
            DEFAULT_PORT
        )
    end
    if message:find("EADDRNOTAVAIL", 1, true) then
        return "The address is not one of this computer's; "
            .. "use --public or one of its IP addresses"
    end
    if message:find("Invalid IP", 1, true) then
        return "--host takes an IP address such as 127.0.0.1"
    end
    return "Check --host and --port, then try again"
end

--- Write the listen failure `message` and a recovery hint to stderr.
local function report_listen_failure(options, message)
    io.stderr:write(string.format(
        "error: listen on %s:%d: %s\n%s\n",
        options.host,
        options.port,
        message,
        get_listen_failure_hint(message, options)
    ))
end

--- Return the URLs that reach a server bound to all interfaces:
--- one per IPv4 address of this computer, loopback first.
local function list_public_urls(port)
    local loopback_urls = {}
    local network_urls = {}
    for _, addresses in pairs(uv.interface_addresses()) do
        for _, address in ipairs(addresses) do
            if address.family == "inet" then
                local target = network_urls
                if address.internal then
                    target = loopback_urls
                end
                target[#target + 1] = string.format(
                    "http://%s:%d/", address.ip, port)
            end
        end
    end
    table.sort(loopback_urls)
    table.sort(network_urls)
    for _, network_url in ipairs(network_urls) do
        loopback_urls[#loopback_urls + 1] = network_url
    end
    return loopback_urls
end

--- Print where the server listens and how to reach it.
local function print_startup_banner(options)
    local runtime = get_runtime_version()
    if options.host ~= PUBLIC_HOST then
        print(string.format(
            "LuaJIT Cutline Analyzer running at http://%s:%d/ (%s)",
            options.host,
            options.port,
            runtime
        ))
        if options.host == DEFAULT_HOST then
            print("Local only. Use --public to allow other computers.")
        end
        return
    end

    local lines = {
        string.format(
            "LuaJIT Cutline Analyzer listening on %s:%d (%s)",
            options.host,
            options.port,
            runtime
        )
    }
    for _, public_url in ipairs(list_public_urls(options.port)) do
        lines[#lines + 1] = "  " .. public_url
    end
    lines[#lines + 1] = "Warning: no authentication; anyone who can "
        .. "reach this port can use it."
    print(table.concat(lines, "\n"))
end

-- =============================================================================
-- Entry Point
-- =============================================================================

local function dispatch_request(req, res)
    local parsed_url = url.parse(req.url)
    local pathname = parsed_url.pathname or "/"
    local handler = ROUTES[req.method .. " " .. pathname]
    if not handler then
        send_text(res, 404, "Not Found")
        return
    end

    local ok, err = pcall(handler, req, res, parsed_url)
    if not ok then
        io.stderr:write("Request error: " .. tostring(err) .. "\n")
        send_json(res, 500, { error = "Internal server error" })
    end
end

--- Start the HTTP server on `options.host`:`options.port`.
local function start_server(options)
    local server = http.createServer(dispatch_request)
    server:listen(options.port, options.host, function()
        print_startup_banner(options)
    end)
end

--- Parse the command line, check the address, then serve.
--- Exits with EXIT_USAGE for bad options and EXIT_LISTEN_FAILED when
--- the address cannot be listened on.
local function main()
    local options, err = parse_options(
        get_script_arguments(),
        os.getenv("PORT")
    )
    if not options then
        io.stderr:write("error: ", err, "\n", USAGE, "\n")
        os.exit(EXIT_USAGE)
    end
    if options.show_help then
        print(HELP_TEXT)
        return
    end

    probe_listen_address(options.host, options.port, function()
        start_server(options)
    end, function(message)
        report_listen_failure(options, message)
        os.exit(EXIT_LISTEN_FAILED)
    end)
end

main()
