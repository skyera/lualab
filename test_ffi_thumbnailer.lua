local ffi = require("ffi")
local thumbnailer = require("ffi_thumbnailer")

local function assert_equal(actual, expected, message)
    assert(actual == expected, string.format("%s: expected %s, got %s", message, expected, actual))
end

local function check_dimensions(sw, sh, mw, mh, ew, eh)
    local width, height = thumbnailer.dimensions_for(sw, sh, mw, mh)
    assert_equal(width, ew, "thumbnail width")
    assert_equal(height, eh, "thumbnail height")
end

check_dimensions(400, 200, 100, 100, 100, 50)
check_dimensions(200, 400, 100, 100, 50, 100)
check_dimensions(20, 10, 100, 100, 20, 10) -- no upscaling

local source = { width = 2, height = 2, pixels = ffi.new("PixelRGB[4]") }
source.pixels[0].r, source.pixels[0].g, source.pixels[0].b = 255, 0, 0
source.pixels[1].r, source.pixels[1].g, source.pixels[1].b = 0, 255, 0
source.pixels[2].r, source.pixels[2].g, source.pixels[2].b = 0, 0, 255
source.pixels[3].r, source.pixels[3].g, source.pixels[3].b = 255, 255, 255
local tiny = thumbnailer.resize_bilinear(source, 1, 1)
assert_equal(tonumber(tiny.pixels[0].r), 128, "bilinear red channel")
assert_equal(tonumber(tiny.pixels[0].g), 128, "bilinear green channel")
assert_equal(tonumber(tiny.pixels[0].b), 128, "bilinear blue channel")

local path = "/tmp/ffi-thumbnailer-test.ppm"
assert(thumbnailer.save_ppm(tiny, path))
local loaded = assert(thumbnailer.load_ppm(path))
assert_equal(loaded.width, 1, "saved PPM width")
assert_equal(loaded.height, 1, "saved PPM height")
assert_equal(tonumber(loaded.pixels[0].r), 128, "saved PPM red channel")
os.remove(path)

print("ffi_thumbnailer: all tests passed")
