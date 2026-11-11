#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- ffi_binscope.lua
-- Unknown-binary structure explorer (LuaJIT FFI, Windows & POSIX).
--
-- Helps work out the layout of a file whose format is not known:
--   - Map    : (default) the file's layout, with the header decoded and every
--              table of fixed-size records located and its fields guessed
--   - Full   : known signatures (also embedded ones), an entropy map merged into
--              regions (zeros / fill / text / structured / dense / packed),
--              ascending u32 tables (likely offset tables) and strings
--   - Probe  : finds a repeating record size and guesses each field's type
--   - Struct : overlays a C struct declaration (ffi.cdef) on the file
--   - Hexdump: classic offset / hex / ASCII view of any window
--
-- The file is read in fixed-size chunks in binary mode, so memory stays flat on
-- large files and no platform-specific mapping API is needed.
--
-- Known limit: on Windows, LuaJIT receives arguments in the ANSI code page, so
-- paths with characters outside that code page cannot be opened.
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

-- json.lua is installed next to this script, which may be started from any
-- working directory, so the script's own directory is searched first.
local script_dir = (arg and arg[0] or ""):gsub("\\", "/"):match("^(.*)/[^/]*$")
if script_dir then
    package.path = script_dir .. "/?.lua;" .. package.path
end
local json = require("json")

local scan = require("binscope_scan")
local records = require("binscope_records")
local struct = require("binscope_struct")

local STRING_CHAR = scan.STRING_CHAR
local as_bytes = scan.as_bytes
local read_uint = scan.read_uint
local read_window = scan.read_window
local same_kind = scan.same_kind
local read_text_file = scan.read_text_file
local hex_offset = scan.hex_offset

-- One table holds the whole API: the functions of the three library modules
-- plus the map, renderers and command line defined below.
local M = {}
for _, library in ipairs({ scan, records, struct }) do
    for name, value in pairs(library) do
        M[name] = value
    end
end

--------------------------------------------------------------------------------
-- 1. Constants
--------------------------------------------------------------------------------
local MIN_BLOCK_SIZE = 16
local MAX_BLOCK_SIZE = 65536
local DEFAULT_LIMIT = 40

local DEFAULT_PROBE_LENGTH = 4096
local MAX_WINDOW_LENGTH = 1024 * 1024

local MAX_TABLE_SPAN = 256 * 1024
local TABLE_SEARCH_BUDGET = 2 * 1024 * 1024
local MAX_DETAILED_TABLES = 8

local MAX_HEADER_SIZE = 512
local DEFAULT_HEADER_SIZE = 64
local MAX_HEADER_ITEMS = 8
local MAX_HEADER_TEXT = 16
local MAX_HEADER_INTEGER = 2 ^ 24
local RECLASSIFY_MAX = 65536
local MAP_STRING_KEEP = 2000
local MAP_STRING_SAMPLES = 5

local DEFAULT_HEXDUMP_LENGTH = 256
local HEXDUMP_WIDTH = 16

local EXIT_OK = 0
local EXIT_FAILURE = 1
local EXIT_USAGE = 2
local EXIT_INTERNAL = 70

local REGION_NOTES = {
    zeros = "zero padding",
    text = "printable text",
    structured = "low-entropy binary: headers or tables",
    dense = "code or mixed data",
    packed = "compressed or encrypted",
}

--------------------------------------------------------------------------------
-- 2. Renderers (pure: data in, string out)
--------------------------------------------------------------------------------
local function display_text(text, full_length)
    local shown = text:gsub("\t", "\\t")
    local suffix = (full_length > #text) and "..." or ""
    return '"' .. shown .. '"' .. suffix
end

-- Appends up to `limit` rendered items, then says how many were left out.
local function append_limited(lines, items, total, limit, render_item)
    local shown = (limit == 0) and #items or math.min(#items, limit)
    for index = 1, shown do
        lines[#lines + 1] = render_item(items[index])
    end
    if total > shown then
        lines[#lines + 1] = string.format(" ... %d more (raise --limit, or --limit 0 for all)",
            total - shown)
    end
end

local function region_note(region)
    if region.class == "fill" then
        return string.format("fill byte 0x%02x", region.fill_byte)
    end
    return REGION_NOTES[region.class]
end

local function render_regions(lines, report, limit)
    lines[#lines + 1] = string.format("Regions (%d, block size %d):", #report.regions, report.block_size)
    lines[#lines + 1] = " OFFSET      SIZE        CLASS       ENTROPY  NOTE"
    append_limited(lines, report.regions, #report.regions, limit, function(region)
        return string.format(" %s  %s  %-10s  %7.2f  %s", hex_offset(region.offset),
            hex_offset(region.size), region.class, region.entropy, region_note(region))
    end)
end

local function render_signatures(lines, report, limit)
    if report.signatures.count == 0 then
        lines[#lines + 1] = "Signatures: none found"
        return
    end
    lines[#lines + 1] = string.format("Signatures (%d):", report.signatures.count)
    append_limited(lines, report.signatures.items, report.signatures.count, limit, function(hit)
        return string.format(" %s  %s", hex_offset(hit.offset), hit.name)
    end)
end

local function render_tables(lines, report, limit)
    if report.tables.count == 0 then
        lines[#lines + 1] = "Ascending u32 tables: none found"
        return
    end
    lines[#lines + 1] = string.format("Ascending u32 tables (%d, possible offset tables):",
        report.tables.count)
    append_limited(lines, report.tables.items, report.tables.count, limit, function(entry)
        return string.format(" %s  %d x u32 %s  0x%x..0x%x", hex_offset(entry.offset),
            entry.count, entry.endian, entry.first, entry.last)
    end)
end

local function render_strings(lines, report, limit)
    if report.strings.count == 0 then
        lines[#lines + 1] = string.format("Strings: none of length >= %d", report.min_string)
        return
    end
    lines[#lines + 1] = string.format("Strings (%d, min length %d):",
        report.strings.count, report.min_string)
    append_limited(lines, report.strings.items, report.strings.count, limit, function(entry)
        return string.format(" %s  %-7s  %s", hex_offset(entry.offset), entry.kind,
            display_text(entry.text, entry.length))
    end)
end

--- Render the whole-file report as text. `limit` caps each list (0 = no cap).
function M.render_report(report, path, limit)
    local lines = {
        string.format("File: %s  (%d bytes)", path, report.size),
        "Type: " .. (report.file_type or "unknown (no known signature at offset 0)"),
        "",
    }
    render_regions(lines, report, limit)
    lines[#lines + 1] = ""
    render_signatures(lines, report, limit)
    lines[#lines + 1] = ""
    render_tables(lines, report, limit)
    lines[#lines + 1] = ""
    render_strings(lines, report, limit)
    return table.concat(lines, "\n") .. "\n"
end

--- Render a probe result (see M.probe) for the window at `offset`.
function M.render_probe(result, offset, length)
    local match = result.score and string.format(" (match %d%%)", result.score * 100) or " (forced)"
    local lines = {
        string.format("Probe @%s  window %d bytes  stride %d%s  rows %d  byte order: %s",
            hex_offset(offset), length, result.stride, match, result.rows, result.byte_order),
        " +OFF   TYPE        NOTE",
    }
    for _, field in ipairs(result.fields) do
        lines[#lines + 1] = string.format(" +%-4d  %-10s  %s", field.offset, field.type, field.note)
    end
    return table.concat(lines, "\n") .. "\n"
end

--- Render struct overlay instances (see M.overlay_struct).
function M.render_struct(instances, type_name, size)
    local lines = {}
    for _, instance in ipairs(instances) do
        lines[#lines + 1] = string.format("%s @%s (%d bytes)", type_name,
            hex_offset(instance.offset), size)
        for _, field in ipairs(instance.fields) do
            lines[#lines + 1] = string.format(" %s  %-24s  %s", hex_offset(field.offset),
                field.name, field.value)
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

local function hexdump_line(bytes, start, count, base_offset)
    local hex, ascii = {}, {}
    for i = 0, HEXDUMP_WIDTH - 1 do
        if i < count then
            local value = bytes[start + i]
            hex[#hex + 1] = string.format("%02x", value)
            ascii[#ascii + 1] = (value >= 0x20 and value <= 0x7E) and string.char(value) or "."
        else
            hex[#hex + 1] = "  "
        end
        if i == HEXDUMP_WIDTH / 2 - 1 then
            hex[#hex + 1] = ""
        end
    end
    return string.format("%s  %s  |%s|", hex_offset(base_offset + start),
        table.concat(hex, " "), table.concat(ascii))
end

--- Render `data` (read from `base_offset`) as offset / hex / ASCII lines.
function M.render_hexdump(data, base_offset)
    local bytes = as_bytes(data)
    local lines = {}
    for start = 0, #data - 1, HEXDUMP_WIDTH do
        local count = math.min(HEXDUMP_WIDTH, #data - start)
        lines[#lines + 1] = hexdump_line(bytes, start, count, base_offset)
    end
    return table.concat(lines, "\n") .. "\n"
end

--------------------------------------------------------------------------------
-- 3. Structure map: header, tables and layout of the whole file
--------------------------------------------------------------------------------
local function is_table_host(region)
    return region.class == "structured" or region.class == "dense"
end

-- Search the structured and dense regions for tables, within a byte budget so
-- huge files stay quick. Returns tables and the number of bytes not searched.
local function find_all_tables(file, size, regions)
    local tables = {}
    local budget = TABLE_SEARCH_BUDGET
    local unsearched = 0
    for _, region in ipairs(regions) do
        local length = is_table_host(region) and math.min(region.size, MAX_TABLE_SPAN, budget) or 0
        if is_table_host(region) then
            unsearched = unsearched + region.size - length
        end
        if length > 0 then
            local data, read_err = read_window(file, size, region.offset, length)
            if not data then
                return nil, read_err
            end
            budget = budget - length
            for _, found in ipairs(M.find_tables(data, region.offset, size, region.class == "dense")) do
                found.label = "T" .. (#tables + 1)
                tables[#tables + 1] = found
            end
        end
    end
    return tables, unsearched
end

local function text_run_length(bytes, position, length)
    local count = 0
    while position + count < length and count < MAX_HEADER_TEXT
        and STRING_CHAR[bytes[position + count]] ~= 0 and bytes[position + count] ~= 0x09 do
        count = count + 1
    end
    return count
end

-- Describe the 4 bytes at `position`. Returns the text, how far to advance
-- and (for integers) the value. Zero words return no text.
local function header_word(bytes, position, length)
    local text_length = text_run_length(bytes, position, length)
    if text_length >= 4 then
        local text = string.format("%q", ffi.string(bytes + position, text_length))
        return text, math.ceil(text_length / 4) * 4
    end
    local little = read_uint(bytes, position, 4, false)
    local big = read_uint(bytes, position, 4, true)
    if little == 0 then
        return nil, 4
    end
    -- The byte order that gives the smaller number is the likelier one.
    local value = math.min(little, big)
    if value >= MAX_HEADER_INTEGER then
        return string.format("bytes %02x %02x %02x %02x", bytes[position], bytes[position + 1],
            bytes[position + 2], bytes[position + 3]), 4
    end
    local order = (big < little) and "u32 BE " or "u32 "
    return order .. string.format("%d", value), 4, value
end

--- Decode header bytes into short descriptions: leading text is a magic,
-- other words are integers or raw bytes, zero words are skipped.
-- Returns { items = { text... }, values = { { offset, value }... } }.
function M.decode_header(data)
    local bytes = as_bytes(data)
    local header = { items = {}, values = {} }
    local position = 0
    while position + 4 <= #data and #header.items < MAX_HEADER_ITEMS do
        local text, advance, value = header_word(bytes, position, #data)
        if text and position == 0 and text:sub(1, 1) == '"' then
            text = "magic " .. text
        end
        if text then
            header.items[#header.items + 1] = text
        end
        if value then
            header.values[#header.values + 1] = { offset = position, value = value }
        end
        position = position + advance
    end
    header.truncated = position + 4 <= #data
    return header
end

-- The header is what precedes a table that starts near the top of the file;
-- failing that, the first bytes of a file that opens with binary data.
local function header_size(tables, regions)
    local first_table = tables[1]
    if first_table and first_table.offset <= MAX_HEADER_SIZE then
        return first_table.offset
    end
    local first_region = regions[1]
    if is_table_host(first_region) then
        return math.min(DEFAULT_HEADER_SIZE, first_region.size)
    end
    return 0
end

local function read_header(file, size, tables, regions)
    local length = header_size(tables, regions)
    if length < 4 then
        return nil
    end
    local data, read_err = read_window(file, size, 0, length)
    if not data then
        return nil, read_err
    end
    local header = M.decode_header(data)
    header.offset = 0
    header.size = length
    header.kind = "header"
    return header
end

local function remainder_of(segment, first, last)
    return {
        offset = first,
        size = last - first,
        class = segment.class,
        fill_byte = segment.fill_byte,
        entropy = segment.entropy,
        recheck = true,
    }
end

-- Cut `item` (a header or table) out of the region list. What is left of a
-- cut region is marked for reclassification, since it is no longer a whole
-- block and may now be, for example, pure padding.
local function carve(segments, item)
    local result = {}
    local item_end = item.offset + item.size
    for _, segment in ipairs(segments) do
        local segment_end = segment.offset + segment.size
        if segment.kind or segment_end <= item.offset or segment.offset >= item_end then
            result[#result + 1] = segment
        else
            if segment.offset < item.offset then
                result[#result + 1] = remainder_of(segment, segment.offset, item.offset)
            end
            if segment_end > item_end then
                result[#result + 1] = remainder_of(segment, item_end, segment_end)
            end
        end
    end
    result[#result + 1] = item
    table.sort(result, function(left, right)
        return left.offset < right.offset
    end)
    return result
end

local function reclassify(file, size, segment)
    if not segment.recheck or segment.size > RECLASSIFY_MAX then
        return true
    end
    local data, read_err = read_window(file, size, segment.offset, segment.size)
    if not data then
        return nil, read_err
    end
    segment.class, segment.entropy, segment.fill_byte = M.classify_block(as_bytes(data), 0, #data)
    return true
end

local function merge_segments(segments)
    local merged = {}
    for _, segment in ipairs(segments) do
        local last = merged[#merged]
        if last and not last.kind and not segment.kind and same_kind(last, segment.class, segment.fill_byte) then
            local total = last.size + segment.size
            last.entropy = (last.entropy * last.size + segment.entropy * segment.size) / total
            last.size = total
        else
            merged[#merged + 1] = segment
        end
    end
    return merged
end

local function build_layout(file, size, regions, header, tables)
    local segments = {}
    for _, region in ipairs(regions) do
        segments[#segments + 1] = remainder_of(region, region.offset, region.offset + region.size)
        segments[#segments].recheck = nil
    end
    if header then
        segments = carve(segments, header)
    end
    for _, found in ipairs(tables) do
        found.kind = "table"
        found.size = found.rows * found.stride
        segments = carve(segments, found)
    end
    for _, segment in ipairs(segments) do
        local ok, read_err = reclassify(file, size, segment)
        if not ok then
            return nil, read_err
        end
    end
    return merge_segments(segments)
end

local SEGMENT_LABELS = {
    zeros = "padding",
    fill = "padding",
    text = "text",
    packed = "packed",
    structured = "data",
    dense = "data",
}

local function segment_label(segment)
    return segment.kind or SEGMENT_LABELS[segment.class]
end

local function is_offset_field(field, found, file_size)
    return field.width == 4 and field.endian and field.ascending
        and field.high < file_size and field.high - field.low >= found.rows * 4
end

-- Names of the layout parts that the values low..high point into.
local function offset_targets(layout, low, high)
    local names, seen = {}, {}
    for _, segment in ipairs(layout) do
        local label = segment.label or segment_label(segment)
        if segment.offset <= high and segment.offset + segment.size > low and not seen[label] then
            seen[label] = true
            names[#names + 1] = label
        end
    end
    return table.concat(names, ", ")
end

-- Mark fields whose values are ascending positions inside the file and say
-- which parts of the layout they point at.
local function link_offsets(tables, layout, file_size)
    for _, found in ipairs(tables) do
        for _, field in ipairs(found.fields) do
            if is_offset_field(field, found, file_size) then
                field.target = "offsets into: " .. offset_targets(layout, field.low, field.high)
            end
        end
    end
end

local function header_hints(header, tables, size, hints)
    for _, entry in ipairs(header and header.values or {}) do
        if entry.value == size then
            hints[#hints + 1] = string.format("header value %d at +%d equals the file size",
                entry.value, entry.offset)
        end
        for _, found in ipairs(tables) do
            if entry.value == found.rows then
                hints[#hints + 1] = string.format("header value %d at +%d matches the record count of %s",
                    entry.value, entry.offset, found.label)
            elseif entry.value == found.offset then
                hints[#hints + 1] = string.format("header value 0x%x at +%d is the offset of %s",
                    entry.value, entry.offset, found.label)
            end
        end
    end
end

local function distinct_strings(strings, wanted)
    local samples, seen = {}, {}
    for _, entry in ipairs(strings.items) do
        if not seen[entry.text] and #samples < wanted then
            seen[entry.text] = true
            samples[#samples + 1] = entry
        end
    end
    return samples
end

-- First string that lies inside each text segment, shown as its sample.
local function attach_text_samples(layout, strings)
    local index = 1
    for _, segment in ipairs(layout) do
        while strings.items[index] and strings.items[index].offset < segment.offset do
            index = index + 1
        end
        local entry = strings.items[index]
        if segment.class == "text" and entry and entry.offset < segment.offset + segment.size then
            segment.sample = entry
        end
    end
end

--- Work out the structure of a whole open file: its layout (header, tables,
-- text, padding, packed data), the fields of every table found, and hints.
-- `options`: block, min_string, progress. Returns the map, or nil and an error.
function M.build_map(file, size, options)
    local report, scan_err = M.scan_file(file, size, {
        block = options.block,
        min_string = options.min_string,
        limit = MAP_STRING_KEEP,
        progress = options.progress,
    })
    if not report then
        return nil, scan_err
    end
    local tables, unsearched = find_all_tables(file, size, report.regions)
    if not tables then
        return nil, unsearched
    end
    local header, header_err = read_header(file, size, tables, report.regions)
    if header_err then
        return nil, header_err
    end
    local layout, layout_err = build_layout(file, size, report.regions, header, tables)
    if not layout then
        return nil, layout_err
    end
    link_offsets(tables, layout, size)
    attach_text_samples(layout, report.strings)
    local hints = {}
    header_hints(header, tables, size, hints)
    return {
        size = size,
        file_type = report.file_type,
        layout = layout,
        tables = tables,
        hints = hints,
        string_count = report.strings.count,
        string_samples = distinct_strings(report.strings, MAP_STRING_SAMPLES),
        unsearched = unsearched,
    }
end

--------------------------------------------------------------------------------
-- 4. Structure map renderer
--------------------------------------------------------------------------------
local C_TYPES = {
    ["f32"] = "float",
    ["f64"] = "double",
    ["u8"] = "uint8_t",
}

-- C declaration for one inferred field, named after its offset in the record.
local function c_field(field)
    local name = "f" .. field.offset
    local text_length = field.type:match("^char%[(%d+)%]$")
    if text_length then
        return string.format("char %s[%s];", name, text_length)
    end
    local bits = field.type:match("^u(%d+) ")
    if bits then
        local comment = (field.endian == "BE") and "  /* big-endian */" or ""
        return string.format("uint%s_t %s;%s", bits, name, comment)
    end
    if field.type == "const" then
        return string.format("uint8_t %s[%d];", name, field.width)
    end
    return string.format("%s %s;", C_TYPES[field.type], name)
end

local function render_struct_guess(lines, found)
    lines[#lines + 1] = string.format(" struct %s_record {", found.label:lower())
    for _, field in ipairs(found.fields) do
        lines[#lines + 1] = "     " .. c_field(field)
    end
    lines[#lines + 1] = " };"
end

local function segment_detail(segment)
    if segment.kind == "header" then
        local more = segment.truncated and ", ..." or ""
        return (#segment.items > 0) and (table.concat(segment.items, ", ") .. more) or "no decodable values"
    end
    if segment.kind == "table" then
        return string.format("%d records x %d bytes (see %s)", segment.rows, segment.stride, segment.label)
    end
    if segment.class == "zeros" then
        return "zeros"
    end
    if segment.class == "fill" then
        return string.format("fill 0x%02x", segment.fill_byte)
    end
    if segment.class == "text" then
        return segment.sample and (display_text(segment.sample.text, segment.sample.length) .. " ...")
            or "printable text"
    end
    return string.format("%s (entropy %.2f)", REGION_NOTES[segment.class], segment.entropy)
end

local function render_layout(lines, map, limit)
    lines[#lines + 1] = "LAYOUT"
    lines[#lines + 1] = " OFFSET      SIZE        KIND     DETAIL"
    append_limited(lines, map.layout, #map.layout, limit, function(segment)
        return string.format(" %s  %s  %-7s  %s", hex_offset(segment.offset), hex_offset(segment.size),
            segment_label(segment), segment_detail(segment))
    end)
end

local function render_table(lines, found)
    local bounds = found.approximate and "  (start and end are approximate)" or ""
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("%s  table @%s  %d records x %d bytes, byte order: %s%s",
        found.label, hex_offset(found.offset), found.rows, found.stride, found.byte_order, bounds)
    for _, field in ipairs(found.fields) do
        local target = field.target and ("  -> " .. field.target) or ""
        lines[#lines + 1] = string.format(" +%-4d  %-10s  %s%s", field.offset, field.type, field.note, target)
    end
    render_struct_guess(lines, found)
end

local function render_map_footer(lines, map)
    lines[#lines + 1] = ""
    if map.string_count > 0 then
        local samples = {}
        for _, entry in ipairs(map.string_samples) do
            samples[#samples + 1] = display_text(entry.text, entry.length)
        end
        lines[#lines + 1] = string.format("Strings: %d found (--full lists them), e.g. %s",
            map.string_count, table.concat(samples, ", "))
    else
        lines[#lines + 1] = "Strings: none found"
    end
    for _, hint in ipairs(map.hints) do
        lines[#lines + 1] = "Hint: " .. hint
    end
    if map.unsearched > 0 then
        lines[#lines + 1] = string.format("Note: %d bytes of binary data were not searched for tables"
            .. " (limit %d per region, %d in total); use --probe <offset> there.",
            map.unsearched, MAX_TABLE_SPAN, TABLE_SEARCH_BUDGET)
    end
end

--- Render a structure map (see M.build_map) as text. `limit` caps the layout
-- rows and the number of tables shown in detail (0 = no cap).
function M.render_map(map, path, limit)
    local lines = {
        string.format("%s  %d bytes  type: %s", path, map.size, map.file_type or "unknown"),
        "",
    }
    render_layout(lines, map, limit)
    local detailed = (limit == 0) and #map.tables or math.min(#map.tables, MAX_DETAILED_TABLES)
    for index = 1, detailed do
        render_table(lines, map.tables[index])
    end
    if #map.tables > detailed then
        lines[#lines + 1] = ""
        lines[#lines + 1] = string.format("... %d more tables (use --limit 0 to show all)",
            #map.tables - detailed)
    end
    if #map.tables == 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "No repeating record tables were found."
    end
    render_map_footer(lines, map)
    return table.concat(lines, "\n") .. "\n"
end

--------------------------------------------------------------------------------
-- 5. Command line
--------------------------------------------------------------------------------
local USAGE = [[
ffi_binscope - explore the structure of an unknown binary file

Usage: luajit ffi_binscope.lua <file> [mode] [options]

With no mode, prints a structure map: the file's layout (header, tables, text,
padding, packed data) and the fields of every record table it can find.

Modes:
  --full                Detailed lists: every region, signature and string
  --probe <offset>      Find the record size at <offset> and guess its fields
  --hexdump <offset>    Hex / ASCII dump starting at <offset>
  --struct <file.h>     Overlay a C struct declared in <file.h> (use with --at)

Options:
  --length <n>          Bytes to read for --probe (default 4096) or --hexdump (256)
  --stride <n>          Record size for --probe, skipping detection
  --at <offset>         Where to overlay the struct (default 0)
  --type <name>         Struct to overlay (default: last one declared)
  --count <n>           Number of consecutive structs to overlay (default 1)
  --block <n>           Entropy block size, 16..65536, multiple of 4 (default 1024)
  --min-string <n>      Shortest string to report (default 6)
  --limit <n>           Rows shown per list; 0 shows everything (default 40)
  --json                Print the map, report, probe or struct result as JSON
  --help                Show this help

Numbers may be decimal or hexadecimal (0x...).
]]

local VALUE_OPTIONS = {
    ["--probe"] = { key = "probe", numeric = true },
    ["--hexdump"] = { key = "hexdump", numeric = true },
    ["--struct"] = { key = "struct" },
    ["--length"] = { key = "length", numeric = true },
    ["--stride"] = { key = "stride", numeric = true },
    ["--at"] = { key = "at", numeric = true },
    ["--type"] = { key = "type" },
    ["--count"] = { key = "count", numeric = true },
    ["--block"] = { key = "block", numeric = true },
    ["--min-string"] = { key = "min_string", numeric = true },
    ["--limit"] = { key = "limit", numeric = true },
}

local function parse_number(text)
    local value
    if text:match("^0[xX]%x+$") then
        value = tonumber(text:sub(3), 16)
    elseif text:match("^%d+$") then
        value = tonumber(text)
    end
    return value
end

local function parse_value_option(options, spec, name, text)
    if text == nil then
        return nil, name .. " needs a value"
    end
    if not spec.numeric then
        options[spec.key] = text
        return true
    end
    local value = parse_number(text)
    if not value then
        return nil, string.format("%s expects a non-negative number, got '%s'", name, text)
    end
    options[spec.key] = value
    return true
end

local function validate_options(options)
    if not options.path then
        return nil, "no input file given"
    end
    local block = options.block
    if block and (block < MIN_BLOCK_SIZE or block > MAX_BLOCK_SIZE or block % 4 ~= 0) then
        return nil, "--block must be 16..65536 and a multiple of 4"
    end
    if options.min_string and options.min_string < 1 then
        return nil, "--min-string must be at least 1"
    end
    if options.length and (options.length < 1 or options.length > MAX_WINDOW_LENGTH) then
        return nil, string.format("--length must be 1..%d", MAX_WINDOW_LENGTH)
    end
    if options.stride and options.stride < 1 then
        return nil, "--stride must be at least 1"
    end
    if options.count and options.count < 1 then
        return nil, "--count must be at least 1"
    end
    local modes = (options.probe and 1 or 0) + (options.hexdump and 1 or 0) + (options.struct and 1 or 0)
        + (options.full and 1 or 0)
    if modes > 1 then
        return nil, "choose only one of --full, --probe, --hexdump, --struct"
    end
    return options
end

--- Parse command-line arguments. Returns options, or nil and a usage error.
function M.parse_arguments(argv)
    local options = {}
    local index = 1
    while index <= #argv do
        local argument = argv[index]
        local spec = VALUE_OPTIONS[argument]
        if spec then
            local parsed, parse_err = parse_value_option(options, spec, argument, argv[index + 1])
            if not parsed then
                return nil, parse_err
            end
            index = index + 1
        elseif argument == "--json" then
            options.json = true
        elseif argument == "--full" then
            options.full = true
        elseif argument == "--help" or argument == "-h" then
            options.help = true
        elseif argument:sub(1, 2) == "--" then
            return nil, "unknown option " .. argument
        elseif options.path then
            return nil, "only one input file is accepted, got extra '" .. argument .. "'"
        else
            options.path = argument
        end
        index = index + 1
    end
    if options.help then
        return options
    end
    return validate_options(options)
end

local function run_report(file, size, options)
    local report, scan_err = M.scan_file(file, size, {
        block = options.block,
        limit = options.limit,
        min_string = options.min_string,
        progress = io.stderr,
    })
    if not report then
        return nil, scan_err
    end
    if options.json then
        report.path = options.path
        return json.encode(report) .. "\n"
    end
    return M.render_report(report, options.path, options.limit or DEFAULT_LIMIT)
end

local function run_map(file, size, options)
    local map, map_err = M.build_map(file, size, {
        block = options.block,
        min_string = options.min_string,
        progress = io.stderr,
    })
    if not map then
        return nil, map_err
    end
    if options.json then
        map.path = options.path
        return json.encode(map) .. "\n"
    end
    return M.render_map(map, options.path, options.limit or DEFAULT_LIMIT)
end

local function run_probe(file, size, options)
    local data, read_err = read_window(file, size, options.probe, options.length or DEFAULT_PROBE_LENGTH)
    if not data then
        return nil, read_err
    end
    local result, reason = M.probe(data, size, options.stride)
    if not result then
        return nil, string.format("probe at 0x%x found nothing: %s (try --stride or --hexdump)",
            options.probe, reason)
    end
    if options.json then
        result.offset = options.probe
        return json.encode(result) .. "\n"
    end
    return M.render_probe(result, options.probe, #data)
end

local function run_hexdump(file, size, options)
    local data, read_err = read_window(file, size, options.hexdump,
        options.length or DEFAULT_HEXDUMP_LENGTH)
    if not data then
        return nil, read_err
    end
    return M.render_hexdump(data, options.hexdump)
end

local function run_struct(file, size, options)
    local declarations, template_err = read_text_file(options.struct)
    if not declarations then
        return nil, template_err
    end
    local ctype, struct_size, type_name = M.load_struct_type(declarations, options.type)
    if not ctype then
        return nil, string.format("template %s: %s", options.struct, struct_size)
    end
    local offset = options.at or 0
    local count = options.count or 1
    local needed = struct_size * count
    local data, read_err = read_window(file, size, offset, needed)
    if not data then
        return nil, read_err
    end
    if #data < needed then
        return nil, string.format("%d x %s needs %d bytes at 0x%x, but only %d remain in the file",
            count, type_name, needed, offset, #data)
    end
    local instances = M.overlay_struct(ctype, data, offset, count)
    if options.json then
        return json.encode(instances) .. "\n"
    end
    return M.render_struct(instances, type_name, struct_size)
end

local function run_mode(file, size, options)
    if options.probe then
        return run_probe(file, size, options)
    end
    if options.hexdump then
        return run_hexdump(file, size, options)
    end
    if options.struct then
        return run_struct(file, size, options)
    end
    if options.full then
        return run_report(file, size, options)
    end
    return run_map(file, size, options)
end

--- Run the tool with `argv`. Returns a process exit code.
function M.main(argv)
    local options, usage_err = M.parse_arguments(argv)
    if not options then
        io.stderr:write("error: ", usage_err, "\nRun with --help for usage.\n")
        return EXIT_USAGE
    end
    if options.help then
        io.stdout:write(USAGE)
        return EXIT_OK
    end
    local file, size = M.open_input(options.path)
    if not file then
        io.stderr:write("error: ", size, "\n")
        return EXIT_FAILURE
    end
    -- Protected so the file handle is closed even if an analysis step throws.
    local ok, output, mode_err = xpcall(run_mode, debug.traceback, file, size, options)
    file:close()
    if not ok then
        io.stderr:write("internal error: ", tostring(output), "\n")
        return EXIT_INTERNAL
    end
    if not output then
        io.stderr:write("error: ", mode_err, "\n")
        return EXIT_FAILURE
    end
    io.stdout:write(output)
    return EXIT_OK
end

--------------------------------------------------------------------------------
-- 6. Entry point
--------------------------------------------------------------------------------
-- Run only when executed as a script; require("ffi_binscope") returns the module.
local script_name = arg and arg[0] and arg[0]:gsub("\\", "/"):match("([^/]+)$")
if script_name == "ffi_binscope.lua" then
    os.exit(M.main(arg))
end

return M
