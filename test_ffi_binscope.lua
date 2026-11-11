#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_ffi_binscope.lua
-- Test suite for ffi_binscope.lua: unit tests of the analysis and rendering
-- functions on synthetic data, and end-to-end runs of the command line
-- (including failure paths and exit codes).
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")
local json = require("json")
local binscope = require("ffi_binscope")

--------------------------------------------------------------------------------
-- 1. Harness
--------------------------------------------------------------------------------
local LUAJIT = (arg and arg[-1] and #arg[-1] > 0) and arg[-1] or "luajit"
local FIXTURE_PREFIX = "_binscope_test_"
local STDOUT_FILE = FIXTURE_PREFIX .. "stdout.tmp"
local STDERR_FILE = FIXTURE_PREFIX .. "stderr.tmp"

local passed_count = 0
local failed_count = 0
local fixture_paths = { STDOUT_FILE, STDERR_FILE }

local function check(condition, description)
    if condition then
        passed_count = passed_count + 1
    else
        failed_count = failed_count + 1
        print("  [FAIL] " .. description)
    end
end

local function check_equal(actual, expected, description)
    local detail = string.format("%s (expected %s, got %s)", description,
        tostring(expected), tostring(actual))
    check(actual == expected, detail)
end

local function check_contains(text, needle, description)
    local detail = string.format("%s (missing %q in %q)", description, needle, tostring(text):sub(1, 300))
    check(type(text) == "string" and text:find(needle, 1, true) ~= nil, detail)
end

local function section(title)
    print("-- " .. title)
end

local function write_fixture(name, data)
    local path = FIXTURE_PREFIX .. name
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
    table.insert(fixture_paths, path)
    return path
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return ""
    end
    local data = file:read("*a")
    file:close()
    return data
end

local function remove_fixtures()
    for _, path in ipairs(fixture_paths) do
        os.remove(path)
    end
end

-- os.execute reports the exit code differently across LuaJIT builds and
-- platforms: a raw wait status (code * 256 on POSIX), the code itself, or the
-- Lua 5.2 style (true/nil, "exit", code).
local function exit_code_of(status, _, code)
    if type(status) == "number" then
        return (status >= 256) and math.floor(status / 256) or status
    end
    return code or (status and 0 or 1)
end

-- Runs the command line; returns exit code, stdout and stderr.
local function run_cli(arguments)
    local command = string.format('"%s" ffi_binscope.lua %s > %s 2> %s',
        LUAJIT, arguments, STDOUT_FILE, STDERR_FILE)
    if ffi.os == "Windows" then
        -- cmd.exe strips the outer quotes of a command that starts with one.
        command = '"' .. command .. '"'
    end
    local code = exit_code_of(os.execute(command))
    return code, read_file(STDOUT_FILE), read_file(STDERR_FILE)
end

local function scan_data(name, data, options)
    local path = write_fixture(name, data)
    local file, size = binscope.open_input(path)
    assert(file, size)
    local report, scan_err = binscope.scan_file(file, size, options or {})
    file:close()
    assert(report, scan_err)
    return report
end

--------------------------------------------------------------------------------
-- 2. Synthetic data builders
--------------------------------------------------------------------------------
local function u16le(value)
    return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32le(value)
    return u16le(value % 65536) .. u16le(math.floor(value / 65536))
end

local function u32be(value)
    return u32le(value):reverse()
end

local function f32le(value)
    local box = ffi.new("float[1]", value)
    return ffi.string(box, 4)
end

-- Deterministic pseudo-random bytes (xorshift32), independent of the platform's
-- rand() so fixtures are identical on every system.
local function random_bytes(count, seed)
    local state = seed * 2654435761 % 4294967296
    local parts = {}
    for i = 1, count do
        state = bit.bxor(state, bit.lshift(state, 13))
        state = bit.bxor(state, bit.rshift(state, 17))
        state = bit.bxor(state, bit.lshift(state, 5))
        parts[i] = string.char(bit.band(bit.rshift(state, 11), 0xFF))
    end
    return table.concat(parts)
end

local function record_table(rows)
    local parts = {}
    for i = 0, rows - 1 do
        parts[#parts + 1] = u32le(0x1000 + i * 0x800) .. u32le(0x700 + (i * 37) % 200)
            .. u16le(1) .. u16le(i) .. u32le(0)
    end
    return table.concat(parts)
end

local HEADER = "FWB1" .. u32le(2) .. u32le(16) .. string.rep("\0", 52)
local TEXT_LINE = "Boot v1.2 starting /dev/ttyS0 at 115200 baud\n"

local function firmware_image()
    return table.concat({
        HEADER,
        record_table(16),
        string.rep("\0", 4096 - 64 - 256),
        TEXT_LINE:rep(100):sub(1, 4096),
        random_bytes(8192, 7),
        string.rep("\255", 2048),
    })
end

--------------------------------------------------------------------------------
-- 3. Entropy and block classification
--------------------------------------------------------------------------------
local function classify(data)
    return binscope.classify_block(ffi.cast("const uint8_t *", data), 0, #data)
end

local function test_entropy()
    section("entropy and block classification")
    local histogram = ffi.new("uint32_t[256]")
    for value = 0, 255 do
        histogram[value] = 4
    end
    check(math.abs(binscope.shannon_entropy(histogram, 1024) - 8) < 1e-9, "uniform histogram is 8 bits")
    ffi.fill(histogram, ffi.sizeof(histogram))
    histogram[65] = 100
    check_equal(binscope.shannon_entropy(histogram, 100), 0, "single-value histogram is 0 bits")

    local class, entropy, fill_byte = classify(string.rep("\0", 1024))
    check_equal(class, "zeros", "all-zero block")
    check_equal(entropy, 0, "zero block entropy")
    check_equal(fill_byte, 0, "zero block fill byte")
    class, _, fill_byte = classify(string.rep("\255", 1024))
    check_equal(class, "fill", "all-0xFF block")
    check_equal(fill_byte, 255, "fill byte value")
    check_equal(classify(TEXT_LINE:rep(30):sub(1, 1024)), "text", "text block")
    check_equal(classify(random_bytes(1024, 3)), "packed", "random 1024-byte block")
    check_equal(classify(random_bytes(256, 4)), "packed", "random 256-byte block")
    check_equal(classify(random_bytes(100, 5)), "packed", "random 100-byte tail block")
    check_equal(classify(record_table(64)), "structured", "record table block")
    check_equal(classify("\1"), "fill", "one-byte block")
    check_equal(classify(random_bytes(8, 6)), "dense", "tiny block is never called packed")
end

--------------------------------------------------------------------------------
-- 4. Whole-file scan
--------------------------------------------------------------------------------
local function check_regions_cover(report)
    local expected_offset = 0
    for _, region in ipairs(report.regions) do
        check_equal(region.offset, expected_offset, "regions are contiguous")
        expected_offset = expected_offset + region.size
    end
    check_equal(expected_offset, report.size, "regions cover the whole file")
end

local function test_regions()
    section("regions")
    local report = scan_data("firmware.bin", firmware_image())
    local expected = {
        { "structured", 0x0000, 0x0400 },
        { "zeros", 0x0400, 0x0c00 },
        { "text", 0x1000, 0x1000 },
        { "packed", 0x2000, 0x2000 },
        { "fill", 0x4000, 0x0800 },
    }
    check_equal(#report.regions, #expected, "region count")
    for index, want in ipairs(expected) do
        local region = report.regions[index] or {}
        check_equal(region.class, want[1], "region " .. index .. " class")
        check_equal(region.offset, want[2], "region " .. index .. " offset")
        check_equal(region.size, want[3], "region " .. index .. " size")
    end
    check_equal(report.regions[5].fill_byte, 255, "fill region byte")
    check(report.regions[4].entropy > 7.5, "packed region entropy is high")
    check_equal(report.file_type, nil, "no signature in the firmware image")
    check_regions_cover(report)

    local small_blocks = scan_data("firmware.bin", firmware_image(), { block = 64 })
    check_equal(small_blocks.block_size, 64, "custom block size is used")
    check_equal(small_blocks.regions[1].size, 0x140, "64-byte blocks locate the table end exactly")
    check_regions_cover(small_blocks)

    local tail = scan_data("tail.bin", random_bytes(1024 + 300, 9))
    check_equal(#tail.regions, 1, "short packed tail joins the packed region")
    check_regions_cover(tail)

    local one_byte = scan_data("one.bin", "A")
    check_equal(#one_byte.regions, 1, "one-byte file has one region")
    check_equal(one_byte.regions[1].size, 1, "one-byte region size")

    local island = string.rep(record_table(64), 2) .. random_bytes(600, 2) .. string.rep("\7", 424)
        .. string.rep(record_table(64), 2)
    local smoothed = scan_data("island.bin", island)
    check_equal(#smoothed.regions, 1, "single noisy block is absorbed into its neighbours")
    check_regions_cover(smoothed)
end

local function test_signatures()
    section("signatures")
    local png = scan_data("image.bin", "\137PNG\r\n\26\n" .. random_bytes(500, 1))
    check_equal(png.file_type, "PNG image", "PNG detected at offset 0")
    check_equal(png.signatures.items[1].offset, 0, "PNG signature offset")

    -- "PK\3\4" is placed across the 65536-byte chunk boundary and once more inside.
    local data = string.rep("\0", 5000) .. "PK\3\4" .. string.rep("\0", 65534 - 5004)
        .. "PK\3\4" .. string.rep("\0", 100) .. "MZ" .. string.rep("\0", 100)
    local embedded = scan_data("embedded.bin", data)
    check_equal(embedded.file_type, nil, "embedded signatures do not set the file type")
    check_equal(embedded.signatures.count, 2, "both ZIP entries found, each once")
    check_equal(embedded.signatures.items[1].offset, 5000, "first embedded offset")
    check_equal(embedded.signatures.items[2].offset, 65534, "signature across chunk boundary")

    local tar = scan_data("archive.bin", string.rep("\0", 257) .. "ustar" .. string.rep("\0", 250))
    check_equal(tar.file_type, "tar archive", "tar magic at 257 marks offset 0")

    local mz = scan_data("program.bin", "MZ" .. string.rep("\0", 62))
    check_equal(mz.file_type, "PE/DOS executable (MZ)", "short magic matched at offset 0")
end

local function find_string(report, text)
    for _, entry in ipairs(report.strings.items) do
        if entry.text == text then
            return entry
        end
    end
    return nil
end

local function utf16(text)
    return (text:gsub(".", "%0\0"))
end

local function test_strings()
    section("strings")
    local data = "\1\2hello world\0\0abc\0" .. string.rep("\1", 20) .. utf16("Version 2") .. "\1\1tab\there\1"
    local report = scan_data("strings.bin", data)
    local hello = find_string(report, "hello world")
    check(hello ~= nil, "ASCII string found")
    check_equal(hello and hello.offset, 2, "ASCII string offset")
    check_equal(hello and hello.kind, "ascii", "ASCII string kind")
    check_equal(find_string(report, "abc"), nil, "string shorter than the minimum is ignored")
    local wide = find_string(report, "Version 2")
    check(wide ~= nil, "UTF-16LE string found")
    check_equal(wide and wide.kind, "utf16le", "UTF-16LE kind")
    check_equal(wide and wide.offset, 39, "UTF-16LE offset")
    check_equal(wide and wide.length, 9, "UTF-16LE length counts characters")
    check(find_string(report, "tab\there") ~= nil, "tab is kept inside a string")
    check_equal(report.strings.count, 3, "total string count")

    local short = scan_data("strings.bin", data, { min_string = 3 })
    check(find_string(short, "abc") ~= nil, "lower minimum finds the short string")

    local boundary = string.rep("\0", 65530) .. "crossing-the-chunk" .. string.rep("\0", 50)
    local crossed = scan_data("boundary.bin", boundary)
    local entry = find_string(crossed, "crossing-the-chunk")
    check(entry ~= nil, "string across a chunk boundary is found whole")
    check_equal(entry and entry.offset, 65530, "boundary string offset")
    check_equal(crossed.strings.count, 1, "boundary string is reported once")

    local long = scan_data("long.bin", "\0" .. string.rep("x", 500) .. "\0")
    check_equal(long.strings.items[1].length, 500, "long string keeps its true length")
    check_equal(#long.strings.items[1].text, 64, "long string text is truncated")

    local many = {}
    for i = 1, 30 do
        many[i] = string.format("string-%03d\0", i)
    end
    local capped = scan_data("many.bin", table.concat(many), { limit = 5 })
    check_equal(capped.strings.count, 30, "capped list keeps the total count")
    check_equal(#capped.strings.items, 5, "capped list stores only the limit")
    local uncapped = scan_data("many.bin", table.concat(many), { limit = 0 })
    check_equal(#uncapped.strings.items, 30, "limit 0 stores everything")
end

local function offsets(encode, count, base)
    local parts = {}
    for i = 0, count - 1 do
        parts[#parts + 1] = encode(base + i * 0x100)
    end
    return table.concat(parts)
end

local function test_tables()
    section("ascending u32 tables")
    local data = string.rep("\255", 64) .. offsets(u32le, 8, 0x200) .. string.rep("\255", 4096)
    local little = scan_data("table_le.bin", data)
    check_equal(little.tables.count, 1, "little-endian offset table found")
    local entry = little.tables.items[1] or {}
    check_equal(entry.offset, 64, "table offset")
    check_equal(entry.count, 8, "table entry count")
    check_equal(entry.endian, "LE", "table byte order")
    check_equal(entry.first, 0x200, "table first value")
    check_equal(entry.last, 0x900, "table last value")

    local big = scan_data("table_be.bin", string.rep("\255", 64) .. offsets(u32be, 6, 0x200)
        .. string.rep("\255", 4096))
    check_equal(big.tables.items[1] and big.tables.items[1].endian, "BE", "big-endian table found")

    local crossing = string.rep("\255", 65528) .. offsets(u32le, 6, 0x400) .. string.rep("\255", 64)
    local crossed = scan_data("table_cross.bin", crossing)
    check_equal(crossed.tables.count, 1, "table across a chunk boundary is one table")
    check_equal(crossed.tables.items[1] and crossed.tables.items[1].count, 6, "crossing table count")

    local counters = string.rep("\255", 16) .. u32le(1) .. u32le(2) .. u32le(3) .. u32le(4) .. u32le(5)
        .. string.rep("\255", 4096)
    check_equal(scan_data("counters.bin", counters).tables.count, 0, "plain counters are not a table")
    check_equal(scan_data("random.bin", random_bytes(8192, 11)).tables.count, 0, "random data has no table")
    local outside = string.rep("\255", 16) .. offsets(u32le, 8, 0x100000) .. string.rep("\255", 64)
    check_equal(scan_data("outside.bin", outside).tables.count, 0, "values past the file end are not offsets")
end

--------------------------------------------------------------------------------
-- 5. Record probing
--------------------------------------------------------------------------------
local function field_at(fields, offset)
    for _, field in ipairs(fields) do
        if field.offset == offset then
            return field
        end
    end
    return {}
end

local function test_stride()
    section("stride detection")
    local data = record_table(16)
    check_equal(binscope.find_stride(ffi.cast("const uint8_t *", data), #data), 16, "16-byte records")

    local mixed = {}
    for i = 0, 39 do
        mixed[#mixed + 1] = f32le(1.5 + i * 0.25) .. u32be(i * 3) .. "ID\0\0"
    end
    local mixed_data = table.concat(mixed)
    check_equal(binscope.find_stride(ffi.cast("const uint8_t *", mixed_data), #mixed_data), 12,
        "12-byte records")

    local constant = string.rep("\0", 512)
    local stride, reason = binscope.find_stride(ffi.cast("const uint8_t *", constant), #constant)
    check_equal(stride, nil, "constant data has no stride")
    check_contains(reason, "no dominant", "constant data reason")
    local noise = random_bytes(2048, 21)
    check_equal(binscope.find_stride(ffi.cast("const uint8_t *", noise), #noise), nil,
        "random data has no stride")
    stride, reason = binscope.find_stride(ffi.cast("const uint8_t *", "abcd"), 4)
    check_equal(stride, nil, "tiny window has no stride")
    check_contains(reason, "too small", "tiny window reason")
end

local function test_fields()
    section("field inference")
    local result = assert(binscope.probe(record_table(16), 1000000))
    check_equal(result.stride, 16, "probe stride")
    check_equal(result.rows, 16, "probe row count")
    check_equal(result.byte_order, "little-endian", "probe byte order")
    check_equal(field_at(result.fields, 0).type, "u32 LE", "aligned offsets are u32 LE")
    check_contains(field_at(result.fields, 0).note, "sequence step +2048", "offset column step")
    check_equal(field_at(result.fields, 4).type, "u32 LE", "size column type")
    check_equal(field_at(result.fields, 8).type, "const", "flags column is constant")
    check_equal(field_at(result.fields, 8).note, "bytes 01 00", "constant bytes are listed")
    check_equal(field_at(result.fields, 10).type, "u16 LE", "id column type")
    check_contains(field_at(result.fields, 10).note, "sequence step +1", "id column sequence")
    check_equal(field_at(result.fields, 12).width, 4, "reserved column width")

    local rows = {}
    for i = 0, 31 do
        local name = ("node%04d"):format(i * 111)
        rows[#rows + 1] = f32le(1.5 + i * 0.37) .. u32be(i * 7 + 300) .. name
            .. u32le(0x9000 + (i * i * 13) % 5000) .. random_bytes(4, 100 + i)
    end
    local mixed = assert(binscope.probe(table.concat(rows), 1000000, 24))
    check_equal(mixed.score, nil, "forced stride has no score")
    check_equal(field_at(mixed.fields, 0).type, "f32", "float column")
    check_equal(field_at(mixed.fields, 4).type, "u32 BE", "big-endian column")
    check_equal(field_at(mixed.fields, 8).type, "char[8]", "text column")
    check_contains(field_at(mixed.fields, 8).note, "node0000", "text column sample")
    check_equal(field_at(mixed.fields, 16).type, "u32 LE", "little-endian column after text")
    check_equal(field_at(mixed.fields, 20).type, "u32 ?", "fully varying bytes have unknown order")
    check_equal(mixed.byte_order, "undetermined", "one LE and one BE field is undetermined")

    local ascending = {}
    for i = 0, 15 do
        ascending[#ascending + 1] = u32le(0x400 + i * i * 9) .. "\0\0\0\0"
    end
    local offsets_probe = assert(binscope.probe(table.concat(ascending), 100000, 8))
    check_contains(field_at(offsets_probe.fields, 0).note, "possible file offsets", "ascending in-file values")

    local failed, reason = binscope.probe(random_bytes(512, 5), 512)
    check_equal(failed, nil, "probe of random data fails")
    check_contains(reason, "no dominant", "probe failure reason")
    failed, reason = binscope.probe("abcdefgh", 8, 16)
    check_equal(failed, nil, "forced stride larger than the window fails")
    check_contains(reason, "needs at least 32 bytes", "oversized stride reason")
end

--------------------------------------------------------------------------------
-- 6. Struct overlay
--------------------------------------------------------------------------------
local STRUCT_DECLARATIONS = [[
enum binscope_test_mode { BINSCOPE_TEST_OFF, BINSCOPE_TEST_ON = 5 };
typedef struct {
    char magic[4];
    uint32_t version;
    uint16_t flags;
    int16_t delta;
    float scale;
    uint64_t big;
    uint8_t raw[4];
    uint16_t list[3];
    struct { uint8_t a; uint8_t b; } pair[2];
    union { uint32_t whole; uint8_t low; };
    enum binscope_test_mode mode;
    uint32_t bits_low : 4;
    uint32_t bits_high : 28;
    double ratio;
} binscope_test_header;
]]

local function value_of(rows, name)
    for _, row in ipairs(rows) do
        if row.name == name then
            return row.value, row.offset
        end
    end
    return nil
end

local function test_struct_overlay()
    section("struct overlay")
    local ctype, size, type_name = binscope.load_struct_type(STRUCT_DECLARATIONS)
    assert(ctype, size)
    check_equal(type_name, "binscope_test_header", "last declared struct is chosen")

    local object = ffi.new(ctype)
    ffi.copy(object.magic, "FWB1", 4)
    object.version = 0xDEADBEEF
    object.flags = 0x8001
    object.delta = -2
    object.scale = 1.5
    object.big = 0x1122334455667788ULL
    object.raw = { 0xDE, 0xAD, 0x00, 0x01 }
    object.list = { 10, 20, 30 }
    object.pair[1].b = 9
    object.whole = 0x01020304
    object.mode = 5
    object.bits_low = 3
    object.bits_high = 100
    object.ratio = 0.25
    local data = ffi.string(object, size) .. ffi.string(object, size)

    local instances = binscope.overlay_struct(ctype, data, 0x100, 2)
    check_equal(#instances, 2, "two instances overlaid")
    check_equal(instances[2].offset, 0x100 + size, "second instance offset")
    local rows = instances[1].fields
    check_equal(value_of(rows, "magic"), '"FWB1"', "char array shown as text")
    check_equal(value_of(rows, "version"), "3735928559 (0xdeadbeef)", "uint32 value")
    check_equal(value_of(rows, "flags"), "32769 (0x8001)", "uint16 value")
    check_equal(value_of(rows, "delta"), "-2 (0xfffe)", "negative int16 value")
    check_equal(value_of(rows, "scale"), "1.5", "float value")
    check_equal(value_of(rows, "big"), "1234605616436508552 (0x1122334455667788)", "uint64 value")
    check_equal(value_of(rows, "raw"), "de ad 00 01", "non-text byte array shown as hex")
    check_contains(value_of(rows, "list"), "10 (0x000a), 20 (0x0014), 30 (0x001e)", "integer array")
    check_equal(value_of(rows, "pair[1].b"), "9 (0x09)", "nested struct array member")
    check_equal(value_of(rows, "whole"), "16909060 (0x01020304)", "anonymous union member")
    check_equal(value_of(rows, "low"), "4 (0x04)", "anonymous union overlapping member")
    check_contains(value_of(rows, "mode"), "5 (0x00000005) (enum)", "enum value")
    check_equal(value_of(rows, "bits_low"), "3 (bitfield)", "bitfield value")
    check_equal(value_of(rows, "ratio"), "0.25", "double value")
    local _, version_offset = value_of(rows, "version")
    check_equal(version_offset, 0x104, "field offset is absolute in the file")

    local rendered = binscope.render_struct(instances, type_name, size)
    check_contains(rendered, "binscope_test_header @0x00000100", "struct render header")
    check_contains(rendered, "pair[1].b", "struct render nested name")

end

local function test_struct_errors()
    section("struct template errors")
    check_equal(binscope.guess_type_name("struct a { int x; };\nstruct b { int y; };"), "struct b",
        "struct tag is guessed")
    check_equal(binscope.guess_type_name("int x;"), nil, "no struct to guess")
    local failed, reason = binscope.load_struct_type("struct { int x")
    check_equal(failed, nil, "invalid declarations are rejected")
    check_contains(reason, "invalid C declarations", "invalid declarations reason")
    failed, reason = binscope.load_struct_type("", "binscope_no_such_type")
    check_contains(reason, "unknown type 'binscope_no_such_type'", "unknown type reason")
    failed, reason = binscope.load_struct_type("typedef int binscope_test_int;", "binscope_test_int")
    check_contains(reason, "is not a struct or union", "non-struct type reason")
    failed, reason = binscope.load_struct_type("int binscope_test_function(int);")
    check_contains(reason, "no struct found", "template without a struct")
end

--------------------------------------------------------------------------------
-- 7. Renderers
--------------------------------------------------------------------------------
local function empty_list()
    return { count = 0, items = {} }
end

local function test_renderers()
    section("renderers")
    local empty = {
        size = 1,
        block_size = 1024,
        min_string = 6,
        regions = { { offset = 0, size = 1, class = "fill", fill_byte = 65, entropy = 0 } },
        signatures = empty_list(),
        strings = empty_list(),
        tables = empty_list(),
    }
    local text = binscope.render_report(empty, "tiny.bin", 40)
    check_contains(text, "File: tiny.bin  (1 bytes)", "report header")
    check_contains(text, "Type: unknown", "unknown type line")
    check_contains(text, "fill byte 0x41", "fill region note")
    check_contains(text, "Signatures: none found", "empty signatures")
    check_contains(text, "Ascending u32 tables: none found", "empty tables")
    check_contains(text, "Strings: none of length >= 6", "empty strings")

    local report = scan_data("firmware.bin", firmware_image())
    local full = binscope.render_report(report, "name with spaces %d %s.bin", 2)
    check_contains(full, "name with spaces %d %s.bin", "path with format characters is printed verbatim")
    check_contains(full, "Regions (5, block size 1024):", "region heading")
    check_contains(full, "... 3 more (raise --limit", "regions are limited")
    check_contains(full, "0x00001000  ascii    \"Boot v1.2 starting", "string row")
    local everything = scan_data("firmware.bin", firmware_image(), { limit = 0 })
    local unlimited = binscope.render_report(everything, "fw.bin", 0)
    check(not unlimited:find("more (raise", 1, true), "limit 0 shows every row")
    check_contains(unlimited, "fill byte 0xff", "last region shown with limit 0")

    local long = scan_data("long.bin", "\0" .. string.rep("x", 500) .. "\0\ta\tb\tc\td\0")
    local long_text = binscope.render_report(long, "long.bin", 40)
    check_contains(long_text, string.rep("x", 64) .. '"...', "truncated string is marked")
    check_contains(long_text, '"\\ta\\tb\\tc\\td"', "tabs are escaped")

    local probe = assert(binscope.probe(record_table(16), 1000000))
    local probe_text = binscope.render_probe(probe, 0x40, 256)
    check_contains(probe_text, "Probe @0x00000040  window 256 bytes  stride 16 (match", "probe header")
    check_contains(probe_text, " +10    u16 LE", "probe field row")
    local forced = assert(binscope.probe(record_table(16), 1000000, 16))
    check_contains(binscope.render_probe(forced, 0, 256), "stride 16 (forced)", "forced probe header")

    local dump = binscope.render_hexdump("ABCDEFGHIJKLMNOPQ\0\255", 0x1f0)
    check_contains(dump, "0x000001f0  41 42 43 44 45 46 47 48  49 4a 4b 4c 4d 4e 4f 50  |ABCDEFGHIJKLMNOP|",
        "full hexdump line")
    check_contains(dump, "0x00000200  51 00 ff" .. string.rep(" ", 42) .. "|Q..|", "partial hexdump line")
    check_equal(binscope.render_hexdump("A", 0), "0x00000000  41" .. string.rep(" ", 48) .. "|A|\n",
        "one-byte hexdump")
end

--------------------------------------------------------------------------------
-- 8. Automatic table discovery and the structure map
--------------------------------------------------------------------------------
local MAP_IMAGE_SIZE = 18432

-- Like firmware_image(), but the header carries the file size and the table's
-- offsets all point inside the file (into the text and packed parts).
local function map_image()
    local rows = {}
    for i = 0, 15 do
        rows[#rows + 1] = u32le(0x1000 + i * 0x300) .. u32le(0x700 + (i * 37) % 200)
            .. u16le(1) .. u16le(i) .. u32le(0)
    end
    return table.concat({
        "FWB1" .. u32le(2) .. u32le(16) .. u32le(MAP_IMAGE_SIZE) .. string.rep("\0", 48),
        table.concat(rows),
        string.rep("\0", 4096 - 64 - 256),
        TEXT_LINE:rep(100):sub(1, 4096),
        random_bytes(8192, 7),
        string.rep("\255", 2048),
    })
end

local function tagged_records(count)
    local rows = {}
    for i = 0, count - 1 do
        rows[#rows + 1] = "\170\85" .. u16le(i * 3) .. u32le(0x20000 + i * 0x40) .. f32le(0.5 + i * 0.125)
            .. u32be(i + 1000) .. random_bytes(4, 300 + i)
    end
    return table.concat(rows)
end

local function test_find_tables()
    section("automatic table discovery")
    local image = map_image():sub(1, 1024)
    local tables = binscope.find_tables(image, 0x8000, 1000000)
    check_equal(#tables, 1, "one table in the header block")
    local found = tables[1] or { fields = {} }
    check_equal(found.offset, 0x8000 + 64, "table start is exact and includes the base offset")
    check_equal(found.stride, 16, "table record size")
    check_equal(found.rows, 16, "table row count stops before the zero padding")
    check_equal(found.approximate, false, "table bounds are exact")
    check_equal(field_at(found.fields, 0).type, "u32 LE", "table field type")
    check_equal(field_at(found.fields, 10).type, "u16 LE", "table id field")

    -- 20-byte records with a constant tag, surrounded by unrelated bytes.
    local data = random_bytes(100, 41) .. tagged_records(40) .. random_bytes(300, 42)
    tables = binscope.find_tables(data, 0, 1000000)
    check_equal(#tables, 1, "table between random data is found")
    found = tables[1] or { fields = {} }
    check_equal(found.offset, 100, "unaligned table start is exact")
    check_equal(found.stride, 20, "20-byte record size")
    check_equal(found.rows, 40, "all 40 records, none of the surrounding bytes")
    check_equal(field_at(found.fields, 0).type, "const", "constant tag field")
    check_equal(field_at(found.fields, 8).type, "f32", "float field")
    check_equal(field_at(found.fields, 12).type, "u32 BE", "big-endian field")

    local floats = {}
    for i = 0, 99 do
        floats[#floats + 1] = f32le(1.5 + i * 0.37) .. f32le(-20.25 + i * 1.1) .. f32le(300.5 - i * 2.3)
    end
    local float_data = table.concat(floats)
    tables = binscope.find_tables(float_data, 0, 1000000)
    check_equal(#tables, 1, "float-only table is found")
    check_equal(tables[1] and tables[1].stride, 12, "float table record size")
    check_equal(tables[1] and tables[1].approximate, true, "table without constant bytes is approximate")
    check_equal(#binscope.find_tables(float_data, 0, 1000000, true), 0, "strict search rejects approximate tables")

    check_equal(#binscope.find_tables(random_bytes(4096, 51), 0, 4096), 0, "random data has no tables")
    check_equal(#binscope.find_tables(string.rep("\0", 4096), 0, 4096), 0, "zeros have no tables")
    check_equal(#binscope.find_tables("abc", 0, 3), 0, "tiny data has no tables")
    check_equal(#binscope.find_tables("", 0, 0), 0, "empty data has no tables")
    check_equal(#binscope.find_tables(record_table(4), 0, 1000), 0, "four records are too few to call a table")
end

-- A NaN bit pattern loaded as a double becomes a corrupt Lua value in LuaJIT,
-- so file bytes must never be loaded as floating point unchecked.
local function test_nan_safety()
    section("NaN bit patterns in file data")
    local rows = {}
    for i = 0, 63 do
        rows[#rows + 1] = u32le(i) .. "\1\0\0\0" .. string.char(i % 251 + 1, 0, 0, 0, 0, 0, 0xF0 + i % 16, 0xFF)
    end
    local data = table.concat(rows)
    local result = assert(binscope.probe(data, 100000, 16))
    for _, field in ipairs(result.fields) do
        check_equal(type(field.type), "string", "field type at +" .. field.offset .. " is a string")
        check(field.type ~= "f64", "NaN column at +" .. field.offset .. " is not called a double")
    end
    local tables = binscope.find_tables(data, 0, 100000)
    check_equal(tables[1] and tables[1].stride, 16, "table of NaN-bearing records is still found")

    local ctype, size = binscope.load_struct_type(
        "struct binscope_test_nan { double d; float f; double list[2]; float pair[2]; };")
    assert(ctype, size)
    local nan_double = string.char(1, 0, 0, 0, 0, 0, 0xF8, 0xFF)
    local nan_float = string.char(1, 0, 0xC0, 0xFF)
    local bytes = nan_double .. nan_float .. "\0\0\0\0" .. nan_double
        .. ffi.string(ffi.new("double[1]", 2.5), 8) .. nan_float .. f32le(0.75)
    local fields = binscope.overlay_struct(ctype, bytes, 0, 1)[1].fields
    check_equal(value_of(fields, "d"), "nan or inf", "NaN double member")
    check_equal(value_of(fields, "f"), "nan or inf", "NaN float member")
    check_equal(value_of(fields, "list"), "nan or inf, 2.5", "double array with a NaN")
    check_equal(value_of(fields, "pair"), "nan or inf, 0.75", "float array with a NaN")
end

local function test_decode_header()
    section("header decoding")
    local header = binscope.decode_header("FWB1" .. u32le(2) .. u32be(16) .. "\0\0\0\0"
        .. "\222\173\190\239" .. u32le(18432))
    check_equal(header.items[1], 'magic "FWB1"', "leading text is the magic")
    check_equal(header.items[2], "u32 2", "little-endian integer")
    check_equal(header.items[3], "u32 BE 16", "big-endian integer")
    check_equal(header.items[4], "bytes de ad be ef", "large word shown as bytes")
    check_equal(header.items[5], "u32 18432", "integer after a zero word")
    check_equal(#header.items, 5, "zero word is skipped")
    check_equal(header.values[1].offset, 4, "value offset")
    check_equal(header.values[3].value, 18432, "value after the raw bytes")
    check_equal(header.truncated, false, "whole header decoded")

    local long = binscope.decode_header(string.rep(u32le(7), 20))
    check_equal(#long.items, 8, "header items are capped")
    check_equal(long.truncated, true, "capped header is marked")
    check_equal(#binscope.decode_header("ab").items, 0, "header shorter than a word")
    check_equal(binscope.decode_header("IDENTIFIER_NAME_LONGER_THAN_CAP" .. u32le(5)).items[1],
        'magic "IDENTIFIER_NAME_"', "long text is cut at the cap")
end

local function build_map_of(name, data)
    local path = write_fixture(name, data)
    local file, size = binscope.open_input(path)
    assert(file, size)
    local map, map_err = binscope.build_map(file, size, {})
    file:close()
    assert(map, map_err)
    return map
end

local function check_layout_covers(map)
    local expected_offset = 0
    for _, segment in ipairs(map.layout) do
        check_equal(segment.offset, expected_offset, "layout is contiguous")
        expected_offset = expected_offset + segment.size
    end
    check_equal(expected_offset, map.size, "layout covers the whole file")
end

local function test_build_map()
    section("structure map")
    local map = build_map_of("map.bin", map_image())
    local expected = {
        { "header", 0x0000, 0x0040 },
        { "table", 0x0040, 0x0100 },
        { "zeros", 0x0140, 0x0ec0 },
        { "text", 0x1000, 0x1000 },
        { "packed", 0x2000, 0x2000 },
        { "fill", 0x4000, 0x0800 },
    }
    check_equal(#map.layout, #expected, "layout row count")
    for index, want in ipairs(expected) do
        local segment = map.layout[index] or {}
        check_equal(segment.kind or segment.class, want[1], "layout row " .. index .. " kind")
        check_equal(segment.offset, want[2], "layout row " .. index .. " offset")
        check_equal(segment.size, want[3], "layout row " .. index .. " size")
    end
    check_layout_covers(map)
    check_equal(#map.tables, 1, "one table in the map")
    local found = map.tables[1]
    check_equal(found.label, "T1", "table label")
    check_equal(found.rows, 16, "map table rows")
    check_equal(field_at(found.fields, 0).target, "offsets into: text, packed", "offset column is linked")
    check_equal(field_at(found.fields, 4).target, nil, "size column is not an offset")
    check_equal(map.layout[1].items[1], 'magic "FWB1"', "header magic")
    check_equal(map.layout[4].sample.text, TEXT_LINE:sub(1, -2), "text row has a sample string")
    local hints = table.concat(map.hints, "\n")
    check_contains(hints, "header value 16 at +8 matches the record count of T1", "record count hint")
    check_contains(hints, "header value 18432 at +12 equals the file size", "file size hint")
    check(map.string_count > 90, "map counts the strings")
    check_equal(map.unsearched, 0, "small file is searched completely")

    local noise = build_map_of("noise.bin", random_bytes(8192, 61))
    check_equal(#noise.tables, 0, "random file has no tables")
    check_equal(#noise.layout, 1, "random file is one layout row")
    check_equal(noise.layout[1].class, "packed", "random file is packed")
    check_layout_covers(noise)

    local text = build_map_of("text.bin", TEXT_LINE:rep(200))
    check_equal(#text.tables, 0, "text file has no tables")
    check_equal(text.layout[1].class, "text", "text file layout")
    local zeros = build_map_of("zeros.bin", string.rep("\0", 5000))
    check_equal(#zeros.layout, 1, "zero file is one layout row")
    check_equal(zeros.layout[1].class, "zeros", "zero file layout")
    local tiny = build_map_of("one.bin", "A")
    check_equal(#tiny.layout, 1, "one-byte file layout")
    check_layout_covers(tiny)

    local headed = build_map_of("headed.bin", "HDR0" .. u32le(3) .. random_bytes(8, 71) .. string.rep("\0", 100))
    check_equal(headed.layout[1].kind, "header", "binary file without a table still shows a header")
    check_equal(headed.layout[1].items[1], 'magic "HDR0"', "header magic without a table")
    check_layout_covers(headed)
end

local function test_render_map()
    section("structure map renderer")
    local text = binscope.render_map(build_map_of("map.bin", map_image()), "fw image %d.bin", 40)
    check_contains(text, "fw image %d.bin  18432 bytes  type: unknown", "map heading")
    check_contains(text, ' 0x00000000  0x00000040  header   magic "FWB1", u32 2, u32 16, u32 18432', "header row")
    check_contains(text, " 0x00000040  0x00000100  table    16 records x 16 bytes (see T1)", "table row")
    check_contains(text, " 0x00000140  0x00000ec0  padding  zeros", "padding row")
    check_contains(text, ' 0x00001000  0x00001000  text     "Boot v1.2 starting', "text row")
    check_contains(text, " 0x00002000  0x00002000  packed   compressed or encrypted (entropy 7.", "packed row")
    check_contains(text, " 0x00004000  0x00000800  padding  fill 0xff", "fill row")
    check_contains(text, "T1  table @0x00000040  16 records x 16 bytes, byte order: little-endian", "table heading")
    check_contains(text, "sequence step +768  -> offsets into: text, packed", "offset target is shown")
    check_contains(text, " struct t1_record {\n     uint32_t f0;\n     uint32_t f4;\n     uint8_t f8[2];\n"
        .. "     uint16_t f10;\n     uint8_t f12[4];\n };", "struct guess")
    check_contains(text, "Strings: ", "string summary")
    check_contains(text, "Hint: header value 16 at +8 matches the record count of T1", "hint line")
    check(not text:find("Note:", 1, true), "no search note for a small file")

    local limited = binscope.render_map(build_map_of("map.bin", map_image()), "fw.bin", 2)
    check_contains(limited, "... 4 more (raise --limit", "layout rows are limited")

    local empty = binscope.render_map(build_map_of("zeros.bin", string.rep("\0", 5000)), "zeros.bin", 40)
    check_contains(empty, "No repeating record tables were found.", "no-table message")
    check_contains(empty, "Strings: none found", "no-string message")

    local mixed = binscope.render_map(build_map_of("mixed.bin",
        random_bytes(100, 41) .. tagged_records(40) .. random_bytes(300, 42)), "mixed.bin", 40)
    check_contains(mixed, "float f8;", "float field in the struct guess")
    check_contains(mixed, "uint32_t f12;  /* big-endian */", "big-endian field is flagged")

    local many = { size = 10, layout = {}, tables = {}, hints = {}, string_count = 0, string_samples = {},
        unsearched = 4096 }
    for index = 1, 10 do
        many.tables[index] = { label = "T" .. index, offset = index, rows = 8, stride = 4,
            byte_order = "undetermined", approximate = true, fields = {} }
    end
    local capped = binscope.render_map(many, "many.bin", 40)
    check_contains(capped, "... 2 more tables (use --limit 0 to show all)", "detailed tables are capped")
    check_contains(capped, "(start and end are approximate)", "approximate tables are flagged")
    check_contains(capped, "Note: 4096 bytes of binary data were not searched for tables", "search limit note")
    check(not binscope.render_map(many, "many.bin", 0):find("more tables", 1, true), "limit 0 shows all tables")
end

local function test_cli_map()
    section("command line: structure map")
    local path = write_fixture("map.bin", map_image())
    local code, out, err = run_cli(path)
    check_equal(code, 0, "map exit code")
    check_equal(err, "", "map writes nothing to stderr")
    check_contains(out, "LAYOUT", "default output is the structure map")
    check_contains(out, "16 records x 16 bytes (see T1)", "map finds the table without options")

    code, out = run_cli(path .. " --json")
    check_equal(code, 0, "map json exit code")
    local decoded = json.decode(out)
    check_equal(#decoded.layout, 6, "json layout rows")
    check_equal(decoded.tables[1].stride, 16, "json table record size")
    check_equal(decoded.tables[1].fields[1].target, "offsets into: text, packed", "json offset target")

    code, out = run_cli(path .. " --full")
    check_contains(out, "Regions (5, block size 1024):", "--full keeps the detailed report")
    code, _, err = run_cli(path .. " --full --probe 0")
    check_equal(code, 2, "--full with another mode is a usage error")
    check_contains(err, "choose only one of --full, --probe, --hexdump, --struct", "mode conflict message")
end

--------------------------------------------------------------------------------
-- 9. Argument parsing
--------------------------------------------------------------------------------
local function test_arguments()
    section("argument parsing")
    local options = assert(binscope.parse_arguments({ "a.bin", "--probe", "0x40", "--length", "256", "--json" }))
    check_equal(options.path, "a.bin", "path")
    check_equal(options.probe, 0x40, "hex offset")
    check_equal(options.length, 256, "decimal length")
    check_equal(options.json, true, "json flag")
    check_equal(assert(binscope.parse_arguments({ "--help" })).help, true, "help needs no file")

    local cases = {
        { { "a.bin", "--probe" }, "--probe needs a value" },
        { { "a.bin", "--probe", "-4" }, "expects a non-negative number, got '-4'" },
        { { "a.bin", "--length", "12x" }, "expects a non-negative number, got '12x'" },
        { { "a.bin", "--bogus" }, "unknown option --bogus" },
        { { "a.bin", "b.bin" }, "only one input file" },
        { {}, "no input file given" },
        { { "a.bin", "--block", "102" }, "--block must be" },
        { { "a.bin", "--block", "8" }, "--block must be" },
        { { "a.bin", "--min-string", "0" }, "--min-string must be" },
        { { "a.bin", "--length", "0" }, "--length must be" },
        { { "a.bin", "--stride", "0" }, "--stride must be" },
        { { "a.bin", "--count", "0" }, "--count must be" },
        { { "a.bin", "--probe", "0", "--hexdump", "0" }, "choose only one" },
    }
    for _, case in ipairs(cases) do
        local parsed, reason = binscope.parse_arguments(case[1])
        check_equal(parsed, nil, "rejected: " .. table.concat(case[1], " "))
        check_contains(reason, case[2], "reason for: " .. table.concat(case[1], " "))
    end
end

--------------------------------------------------------------------------------
-- 10. Command line, end to end
--------------------------------------------------------------------------------
local function test_cli_success()
    section("command line: success paths")
    local path = write_fixture("cli.bin", firmware_image())
    local code, out, err = run_cli(path .. " --full")
    check_equal(code, 0, "report exit code")
    check_equal(err, "", "report writes nothing to stderr")
    check_contains(out, "(18432 bytes)", "report shows the file size")
    check_contains(out, "0x00002000  0x00002000  packed", "report shows the packed region")

    code, out = run_cli(path .. " --probe 0x40 --length 256")
    check_equal(code, 0, "probe exit code")
    check_contains(out, "stride 16", "probe finds the stride")

    code, out = run_cli(path .. " --hexdump 0 --length 16")
    check_equal(code, 0, "hexdump exit code")
    check_contains(out, "|FWB1", "hexdump shows the magic")

    local template = write_fixture("cli.h", "struct binscope_cli_entry { uint32_t offset; uint32_t size;"
        .. " uint16_t flags; uint16_t id; uint32_t reserved; };\r\n")
    code, out = run_cli(path .. " --struct " .. template .. " --at 0x50 --count 2")
    check_equal(code, 0, "struct exit code")
    check_contains(out, "struct binscope_cli_entry @0x00000050 (16 bytes)", "struct header")
    check_contains(out, "6144 (0x00001800)", "struct field value")
    check_contains(out, "@0x00000060", "second struct instance")

    code, out = run_cli(path .. " --full --json --limit 3")
    check_equal(code, 0, "json exit code")
    local decoded = json.decode(out)
    check_equal(decoded.size, 18432, "json size")
    check_equal(#decoded.regions, 5, "json regions")
    check_equal(decoded.regions[4].class, "packed", "json region class")
    check_equal(decoded.strings.count, scan_data("cli.bin", firmware_image()).strings.count,
        "json string count matches an in-process scan")
    check(decoded.strings.count > 90, "json string count covers the text region")
    check_equal(#decoded.strings.items, 3, "json honours --limit")

    code, out = run_cli(path .. " --probe 0x40 --length 256 --json")
    check_equal(json.decode(out).stride, 16, "json probe stride")

    code, out = run_cli("--help")
    check_equal(code, 0, "help exit code")
    check_contains(out, "Usage: luajit ffi_binscope.lua <file>", "help text")

    code, out = run_cli(write_fixture("one.bin", "Z"))
    check_equal(code, 0, "one-byte file is analysed")
    check_contains(out, "  1 bytes  ", "one-byte file size")
end

local function test_cli_binary_safety()
    section("command line: binary-safe reads and unusual paths")
    -- Text-mode reads on Windows would shrink CRLF and stop at 0x1A (Ctrl-Z).
    local tricky = "A\r\nB\26C\r\n" .. string.rep("\26\r\n", 100)
    local code, out = run_cli(write_fixture("crlf.bin", tricky) .. " --hexdump 0 --length 16")
    check_equal(code, 0, "CRLF/Ctrl-Z file exit code")
    check_contains(out, "41 0d 0a 42 1a 43 0d 0a", "CR, LF and 0x1A bytes are read unchanged")
    code, out = run_cli(FIXTURE_PREFIX .. "crlf.bin")
    check_contains(out, string.format("  %d bytes  ", #tricky), "CRLF/Ctrl-Z file is read to its full size")

    local spaced = write_fixture("with space.bin", firmware_image())
    code, out = run_cli('"' .. spaced .. '"')
    check_equal(code, 0, "path with a space")
    check_contains(out, "with space.bin", "spaced path is echoed")

    if ffi.os == "Windows" then
        print("  [SKIP] non-ASCII path: LuaJIT on Windows receives arguments in the ANSI code page")
        return
    end
    local unicode = write_fixture("数据 café.bin", firmware_image())
    code, out = run_cli('"' .. unicode .. '"')
    check_equal(code, 0, "path with non-ASCII characters")
    check_contains(out, "  18432 bytes  ", "non-ASCII path is read")
end

local function test_cli_failures()
    section("command line: failure paths")
    local path = write_fixture("cli.bin", firmware_image())
    local missing = FIXTURE_PREFIX .. "does_not_exist.bin"
    local code, out, err = run_cli(missing)
    check_equal(code, 1, "missing file exit code")
    check_equal(out, "", "missing file prints nothing on stdout")
    check_contains(err, "error: cannot open " .. missing, "missing file message names the path")

    code, _, err = run_cli(write_fixture("empty.bin", ""))
    check_equal(code, 1, "empty file exit code")
    check_contains(err, "is empty (0 bytes)", "empty file message")

    code, _, err = run_cli(".")
    check_equal(code, 1, "directory exit code")
    check_contains(err, "error: ", "directory message")

    code, _, err = run_cli(path .. " --hexdump 0x100000")
    check_equal(code, 1, "offset past the end exit code")
    check_contains(err, "offset 0x100000 is beyond the end of the file (18432 bytes)", "offset message")

    code, _, err = run_cli(path .. " --probe 0x2000")
    check_equal(code, 1, "probe of random data exit code")
    check_contains(err, "found nothing: no dominant repeating record size", "probe failure message")
    check_contains(err, "try --stride or --hexdump", "probe failure gives a next step")

    code, _, err = run_cli(path .. " --struct " .. missing)
    check_equal(code, 1, "missing template exit code")
    check_contains(err, "cannot open template", "missing template message")

    local broken = write_fixture("broken.h", "struct binscope_broken { int x")
    code, _, err = run_cli(path .. " --struct " .. broken)
    check_equal(code, 1, "broken template exit code")
    check_contains(err, "invalid C declarations", "broken template message")

    local template = write_fixture("big.h", "struct binscope_big { uint8_t data[4096]; };")
    code, _, err = run_cli(path .. " --struct " .. template .. " --at 0x4000")
    check_equal(code, 1, "struct past the end exit code")
    check_contains(err, "needs 4096 bytes at 0x4000, but only 2048 remain", "struct size message")

    code, out, err = run_cli(path .. " --bogus")
    check_equal(code, 2, "usage error exit code")
    check_equal(out, "", "usage error prints nothing on stdout")
    check_contains(err, "error: unknown option --bogus", "usage error message")
    check_contains(err, "--help", "usage error points at --help")

    code, _, err = run_cli("")
    check_equal(code, 2, "no arguments exit code")
    check_contains(err, "no input file given", "no arguments message")
end

--------------------------------------------------------------------------------
-- 11. Bytecode scoping
--------------------------------------------------------------------------------
local STANDARD_GLOBALS = {
    require = true, io = true, os = true, string = true, math = true, table = true, debug = true,
    ipairs = true, pairs = true, tonumber = true, tostring = true, type = true, pcall = true,
    xpcall = true, arg = true, package = true,
}

-- Bytecode listing of a Lua file, produced in-process by LuaJIT's own jit.bc
-- module. The repo's locally built interpreter keeps that module under
-- LuaJIT/src, so that directory is appended as a fallback search path.
local function bytecode_listing(path)
    package.path = package.path .. ";LuaJIT/src/?.lua"
    local loaded, bytecode = pcall(require, "jit.bc")
    if not loaded then
        return nil, bytecode
    end
    local parts = {}
    local sink = {}
    function sink.write(_, ...)
        parts[#parts + 1] = table.concat({ ... })
    end
    function sink.flush()
    end
    function sink.close()
    end
    bytecode.dump(assert(loadfile(path)), sink, true)
    return table.concat(parts)
end

-- A misspelt local silently becomes a nil global in Lua; the bytecode listing
-- shows every global read (GGET) and write (GSET), so stray ones are caught
-- even in branches no test executes.
local SOURCE_FILES = { "ffi_binscope.lua", "binscope_scan.lua", "binscope_records.lua", "binscope_struct.lua" }

-- Names of the globals a bytecode listing writes, or reads outside the
-- standard set, and how many global accesses it contains in total.
local function stray_globals(listing)
    local stray = {}
    local access_count = 0
    for line in listing:gmatch("[^\n]+") do
        local name = line:match('G[GS]ET%s+%d+%s+%d+%s+;%s+"([^"]+)"')
        if name then
            access_count = access_count + 1
        end
        if name and (line:find("GSET", 1, true) or not STANDARD_GLOBALS[name]) then
            stray[#stray + 1] = name
        end
    end
    return stray, access_count
end

local function test_no_stray_globals()
    section("bytecode scoping")
    for _, path in ipairs(SOURCE_FILES) do
        local listing, load_err = bytecode_listing(path)
        if not listing then
            print("  [SKIP] jit.bc is not available to this interpreter: " .. tostring(load_err))
            return
        end
        local stray, access_count = stray_globals(listing)
        check(access_count > 5, "bytecode listing of " .. path .. " shows its global accesses")
        check_equal(table.concat(stray, ", "), "", "no undeclared globals in " .. path)
    end
end

--------------------------------------------------------------------------------
-- 12. Entry point
--------------------------------------------------------------------------------
local TESTS = {
    test_entropy,
    test_regions,
    test_signatures,
    test_strings,
    test_tables,
    test_stride,
    test_fields,
    test_struct_overlay,
    test_struct_errors,
    test_renderers,
    test_find_tables,
    test_nan_safety,
    test_decode_header,
    test_build_map,
    test_render_map,
    test_arguments,
    test_cli_success,
    test_cli_map,
    test_cli_binary_safety,
    test_cli_failures,
    test_no_stray_globals,
}

print("================================================================================")
print("  ffi_binscope test suite")
print("================================================================================")

-- Fixtures are removed even when a test throws.
local ok, failure = xpcall(function()
    for _, test in ipairs(TESTS) do
        test()
    end
end, debug.traceback)
remove_fixtures()

if not ok then
    print("  [ERROR] test suite aborted: " .. tostring(failure))
    os.exit(1)
end
print(string.format("\n%d passed, %d failed", passed_count, failed_count))
os.exit(failed_count == 0 and 0 or 1)
