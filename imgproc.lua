#!/usr/bin/env luajit
-- imgproc.lua: writes an RGB gradient test image as a binary PPM (P6).
-- Usage: luajit imgproc.lua [output_path]

local ffi = require("ffi")

local IMAGE_WIDTH = 256
local IMAGE_HEIGHT = 256
local CHANNEL_COUNT = 3
local CHANNEL_MAX = 255
local BLUE_LEVEL = 128
local DEFAULT_OUTPUT_PATH = "gradient.ppm"

--- Builds a width x height RGB buffer: red ramps along x, green along y.
local function build_gradient(width, height)
    local pixels = ffi.new("uint8_t[?]", width * height * CHANNEL_COUNT)
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local offset = (y * width + x) * CHANNEL_COUNT
            pixels[offset] = math.floor(x * CHANNEL_MAX / (width - 1))
            pixels[offset + 1] = math.floor(y * CHANNEL_MAX / (height - 1))
            pixels[offset + 2] = BLUE_LEVEL
        end
    end
    return pixels
end

--- Writes pixels as a P6 file. Returns the byte count, or nil and an error.
local function write_ppm(path, pixels, width, height)
    local file, open_err = io.open(path, "wb")
    if not file then
        return nil, "cannot open for writing: " .. open_err
    end
    local header = string.format("P6\n%d %d\n%d\n", width, height, CHANNEL_MAX)
    local body = ffi.string(pixels, width * height * CHANNEL_COUNT)
    local written, write_err = file:write(header, body)
    local closed, close_err = file:close()
    if not written then
        return nil, "write failed for " .. path .. ": " .. write_err
    end
    if not closed then
        return nil, "close failed for " .. path .. ": " .. close_err
    end
    return #header + #body
end

--- Confirms the file on disk has the expected size. Returns true or nil, err.
local function verify_size(path, expected_bytes)
    local file, open_err = io.open(path, "rb")
    if not file then
        return nil, "cannot reopen to verify: " .. open_err
    end
    local actual_bytes = file:seek("end")
    file:close()
    if actual_bytes ~= expected_bytes then
        return nil, string.format(
            "%s is %d bytes, expected %d",
            path,
            actual_bytes,
            expected_bytes
        )
    end
    return true
end

local function fail(message)
    io.stderr:write("error: ", message, "\n")
    io.stderr:write("hint: check that the directory exists and is writable\n")
    os.exit(1)
end

local function main()
    local path = arg[1] or DEFAULT_OUTPUT_PATH
    local pixels = build_gradient(IMAGE_WIDTH, IMAGE_HEIGHT)
    local byte_count, write_err = write_ppm(
        path,
        pixels,
        IMAGE_WIDTH,
        IMAGE_HEIGHT
    )
    if not byte_count then
        fail(write_err)
    end
    local verified, verify_err = verify_size(path, byte_count)
    if not verified then
        fail(verify_err)
    end
    print(string.format(
        "wrote %s (%dx%d, %d bytes)",
        path,
        IMAGE_WIDTH,
        IMAGE_HEIGHT,
        byte_count
    ))
end

main()
