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

-- =============================================================================
-- Constants
-- =============================================================================

local HOST = "127.0.0.1"
local DEFAULT_PORT = 8080
local PORT = tonumber(os.getenv("PORT")) or DEFAULT_PORT

local BASE_DIR = (module and module.dir) or process.cwd()
local PUBLIC_DIR = path.join(BASE_DIR, "public")
local MIME_HTML = "text/html; charset=utf-8"
local MIME_JS = "application/javascript; charset=utf-8"

local RGBA_CHANNELS = 4
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
local next_image_id = 1

-- =============================================================================
-- Helpers
-- =============================================================================

--- Clamp `value` into the inclusive range [`low`, `high`].
local function clamp(value, low, high)
    if value < low then
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

--- Read the complete HTTP request body and invoke `on_complete(body)`.
local function read_request_body(req, on_complete)
    local chunks = {}
    req:on("data", function(chunk)
        chunks[#chunks + 1] = chunk
    end)
    req:on("end", function()
        on_complete(table.concat(chunks))
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

--- Parse cutline segment coordinates from `params` with defaults for `image`.
local function parse_segment_params(params, image)
    return {
        x1 = tonumber(params.x1) or 0,
        y1 = tonumber(params.y1) or 0,
        x2 = tonumber(params.x2) or (image.width - 1),
        y2 = tonumber(params.y2) or (image.height - 1),
        samples = tonumber(params.samples)
    }
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

    local buffer = ffi.new("uint8_t[?]", expected_bytes)
    ffi.copy(buffer, body, expected_bytes)

    local image_id = tostring(next_image_id)
    next_image_id = next_image_id + 1
    images[image_id] = { width = w, height = h, buffer = buffer }
    return image_id
end

--- Store a raw RGBA image buffer uploaded from the browser canvas.
local function store_uploaded_image(req, res)
    local w = tonumber(req.headers["x-image-width"])
    local h = tonumber(req.headers["x-image-height"])
    if not w or not h or w <= 0 or h <= 0 then
        local msg = "Missing or invalid X-Image-Width / X-Image-Height"
        send_json(res, 400, { error = msg })
        return
    end

    read_request_body(req, function(body)
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
    read_request_body(req, function(body)
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
        local segment = parse_segment_params(payload, image)
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

    local segment = parse_segment_params(query, image)
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
    ["/colormaps.js"] = { file = "colormaps.js", mime = MIME_JS }
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
    ["GET /api/health"] = serve_health,
    ["POST /api/image"] = store_uploaded_image,
    ["POST /api/cutline"] = serve_cutline_profile,
    ["GET /api/export"] = export_cutline_csv
}

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

local server = http.createServer(dispatch_request)
server:listen(PORT, HOST, function()
    print(string.format(
        "LuaJIT Cutline Analyzer running at http://%s:%d/ (%s)",
        HOST,
        PORT,
        get_runtime_version()
    ))
end)
