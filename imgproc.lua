#!/usr/bin/env luajit
-- imgproc.lua: writes an RGB gradient test image as a binary PPM (P6), and
-- reports on existing PPM files.
-- Usage: luajit imgproc.lua [output_path]
--        luajit imgproc.lua info <path>

local ffi = require("ffi")

local IMAGE_WIDTH = 256
local IMAGE_HEIGHT = 256
local CHANNEL_COUNT = 3
local CHANNEL_MAX = 255
local BLUE_LEVEL = 128
local MAX_DIMENSION = 16384
local DEFAULT_OUTPUT_PATH = "gradient.ppm"
local WRITE_HINT = "check that the directory exists and is writable"
local READ_HINT = "check that the file exists and is readable"
local INFO_USAGE_HINT = "usage: luajit imgproc.lua info <path>"
local FORMAT_HINT = "expected an 8-bit binary PPM (P6) file without comments"
local PPM_HEADER_PATTERN = "^P6%s+(%d+)%s+(%d+)%s+(%d+)%s()"

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

--- Reads a whole file as bytes. Returns the content, or nil and an error.
local function read_file(path)
    local file, open_err = io.open(path, "rb")
    if not file then
        return nil, "cannot open for reading: " .. open_err
    end
    local content, read_err = file:read("*a")
    file:close()
    if not content then
        return nil, "read failed for " .. path .. ": " .. read_err
    end
    return content
end

--- Parses a P6 header. Returns a table with width, height, max_value and
--- data_start (position of the first pixel byte), or nil and an error.
local function parse_ppm_header(content)
    local width, height, max_value, data_start =
        content:match(PPM_HEADER_PATTERN)
    if not width then
        return nil, "no binary PPM (P6) header found"
    end
    return {
        width = tonumber(width),
        height = tonumber(height),
        max_value = tonumber(max_value),
        data_start = data_start,
    }
end

local function is_valid_dimension(value)
    return value >= 1 and value <= MAX_DIMENSION
end

--- Checks that a parsed header describes an image this program can load and
--- that all its pixel bytes are present. Returns true, or nil and an error.
local function validate_ppm(header, content_length)
    if header.max_value ~= CHANNEL_MAX then
        return nil, string.format(
            "max value %d is not supported (only %d)",
            header.max_value,
            CHANNEL_MAX
        )
    end
    local width, height = header.width, header.height
    if not (is_valid_dimension(width) and is_valid_dimension(height)) then
        return nil, string.format(
            "invalid size %dx%d (each side must be 1 to %d)",
            width,
            height,
            MAX_DIMENSION
        )
    end
    local expected_bytes = width * height * CHANNEL_COUNT
    local available_bytes = content_length - header.data_start + 1
    if available_bytes < expected_bytes then
        return nil, string.format(
            "pixel data is truncated: %d of %d bytes",
            available_bytes,
            expected_bytes
        )
    end
    return true
end

local function fail(message, hint)
    io.stderr:write("error: ", message, "\n")
    io.stderr:write("hint: ", hint, "\n")
    os.exit(1)
end

local function show_info(path)
    if not path then
        fail("info needs a file path", INFO_USAGE_HINT)
    end
    local content, read_err = read_file(path)
    if not content then
        fail(read_err, READ_HINT)
    end

    local header, header_err = parse_ppm_header(content)
    if not header then
        fail(path .. ": " .. header_err, FORMAT_HINT)
    end
    local valid, validation_err = validate_ppm(header, #content)
    if not valid then
        fail(path .. ": " .. validation_err, FORMAT_HINT)
    end
    print(string.format(
        "%s: %dx%d, max value %d, pixels start at byte %d",
        path,
        header.width,
        header.height,
        header.max_value,
        header.data_start
    ))
end

local function write_gradient(path)
    local pixels = build_gradient(IMAGE_WIDTH, IMAGE_HEIGHT)
    local byte_count, write_err = write_ppm(
        path,
        pixels,
        IMAGE_WIDTH,
        IMAGE_HEIGHT
    )
    if not byte_count then
        fail(write_err, WRITE_HINT)
    end
    local verified, verify_err = verify_size(path, byte_count)
    if not verified then
        fail(verify_err, WRITE_HINT)
    end
    print(string.format(
        "wrote %s (%dx%d, %d bytes)",
        path,
        IMAGE_WIDTH,
        IMAGE_HEIGHT,
        byte_count
    ))
end

local function main()
    if arg[1] == "info" then
        show_info(arg[2])
    else
        write_gradient(arg[1] or DEFAULT_OUTPUT_PATH)
    end
end

main()
