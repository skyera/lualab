-- =============================================================================
-- Pixel Live - FFI-backed Pixel Board
--
-- Stores a 2D grid of palette indices (0..15) in a contiguous LuaJIT FFI
-- uint8_t buffer using 0-based (x, y) coordinates.
-- =============================================================================

local ffi = require("ffi")

local MAX_DIM = 256
local MIN_COLOR = 0
local MAX_COLOR = 15

local HEX_CHARS = {
    [0] = "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", "a", "b", "c", "d", "e", "f",
}

local function is_integer_in_range(value, min_val, max_val)
    return type(value) == "number"
        and value == value
        and value == math.floor(value)
        and value >= min_val
        and value <= max_val
end

-- =============================================================================
-- Board Class
-- =============================================================================

local M = {}
local Board = {}
Board.__index = Board

--- Create a new width by height board initialized to color 0
--- Returns the board instance, or nil, err for invalid dimensions.
function M.new(width, height)
    if not is_integer_in_range(width, 1, MAX_DIM) then
        return nil, "invalid board width: " .. tostring(width)
    end
    if not is_integer_in_range(height, 1, MAX_DIM) then
        return nil, "invalid board height: " .. tostring(height)
    end

    local size = width * height
    local instance = {
        width = width,
        height = height,
        size = size,
        pixels = ffi.new("uint8_t[?]", size),
    }
    return setmetatable(instance, Board)
end

--- Return the color index (0..15) at 0-based (x, y), or nil, err.
function Board:get(x, y)
    if not is_integer_in_range(x, 0, self.width - 1) then
        return nil, "x out of bounds: " .. tostring(x)
    end
    if not is_integer_in_range(y, 0, self.height - 1) then
        return nil, "y out of bounds: " .. tostring(y)
    end
    return self.pixels[y * self.width + x]
end

--- Set the pixel at 0-based (x, y) to color (0..15).
--- Returns true, or nil, err if coordinates or color are invalid.
function Board:set(x, y, color)
    if not is_integer_in_range(x, 0, self.width - 1) then
        return nil, "x out of bounds: " .. tostring(x)
    end
    if not is_integer_in_range(y, 0, self.height - 1) then
        return nil, "y out of bounds: " .. tostring(y)
    end
    if not is_integer_in_range(color, MIN_COLOR, MAX_COLOR) then
        return nil, "invalid color index: " .. tostring(color)
    end

    self.pixels[y * self.width + x] = color
    return true
end

--- Reset every pixel on the board to color 0.
function Board:clear()
    ffi.fill(self.pixels, self.size, 0)
end

--- Serialize all pixels in row-major order as a lowercase hex string
function Board:to_hex()
    local chars = {}
    for i = 0, self.size - 1 do
        chars[i + 1] = HEX_CHARS[self.pixels[i]]
    end
    return table.concat(chars)
end

return M
