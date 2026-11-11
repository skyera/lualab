#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- ffi_binscope.lua
-- Unknown-binary structure explorer (LuaJIT FFI, Windows & POSIX).
--
-- Helps work out the layout of a file whose format is not known:
--   - Report : known signatures (also embedded ones), an entropy map merged into
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

local M = {}

--------------------------------------------------------------------------------
-- 1. Constants
--------------------------------------------------------------------------------
local LN2 = math.log(2)
local CHUNK_TARGET_SIZE = 65536
local MAX_REGULAR_FILE_SIZE = 2 ^ 62
local PROGRESS_MIN_FILE_SIZE = 32 * 1024 * 1024

local DEFAULT_BLOCK_SIZE = 1024
local MIN_BLOCK_SIZE = 16
local MAX_BLOCK_SIZE = 65536
local DEFAULT_LIMIT = 40
local DEFAULT_MIN_STRING = 6
local MAX_STRING_TEXT = 64

-- A block is "text" when at least this share of its bytes is printable.
local TEXT_RATIO = 0.9
-- A block is "packed" when its entropy reaches this share of what random data
-- of the same length would measure; below STRUCTURED_RATIO it is "structured".
local PACKED_RATIO = 0.94
local STRUCTURED_RATIO = 0.6
local MIN_PACKED_BLOCK = 32

local MIN_TABLE_ENTRIES = 4

local DEFAULT_PROBE_LENGTH = 4096
local MAX_WINDOW_LENGTH = 1024 * 1024
local MAX_STRIDE = 256
local MIN_STRIDE_CONTRAST = 0.15
local STRIDE_TOLERANCE = 0.02
local MIN_TEXT_FIELD = 4
local FLOAT_MIN_MAGNITUDE = 1e-4
local FLOAT_MAX_MAGNITUDE = 1e9

local DEFAULT_HEXDUMP_LENGTH = 256
local HEXDUMP_WIDTH = 16
local MAX_ARRAY_VALUES = 8
local MAX_STRUCT_ELEMENTS = 4

local EXIT_OK = 0
local EXIT_FAILURE = 1
local EXIT_USAGE = 2
local EXIT_INTERNAL = 70

-- LuaJIT ctype kinds and flags, as reported by ffi.typeinfo().
local CT_NUM = 0
local CT_STRUCT = 1
local CT_PTR = 2
local CT_ARRAY = 3
local CT_ENUM = 5
local CT_TYPEDEF = 7
local CT_ATTRIB = 8
local CT_FIELD = 9
local CT_BITFIELD = 10
local CTF_BOOL = 0x08000000
local CTF_FP = 0x04000000

-- `at` is where the magic sits inside the format; `anywhere` also searches for
-- it past offset 0. Magics shorter than 4 bytes are matched at offset 0 only,
-- because they occur by chance too often inside unrelated data.
local SIGNATURES = {
    { name = "ELF executable/object", magic = "\127ELF", anywhere = true },
    { name = "PE/DOS executable (MZ)", magic = "MZ" },
    { name = "PNG image", magic = "\137PNG\r\n\26\n", anywhere = true },
    { name = "JPEG image", magic = "\255\216\255" },
    { name = "GIF image", magic = "GIF87a", anywhere = true },
    { name = "GIF image", magic = "GIF89a", anywhere = true },
    { name = "BMP image", magic = "BM" },
    { name = "ZIP archive entry", magic = "PK\3\4", anywhere = true },
    { name = "gzip stream", magic = "\31\139\8" },
    { name = "bzip2 stream", magic = "BZh" },
    { name = "xz stream", magic = "\2537zXZ\0", anywhere = true },
    { name = "zstd frame", magic = "\40\181\47\253", anywhere = true },
    { name = "7z archive", magic = "7z\188\175\39\28", anywhere = true },
    { name = "PDF document", magic = "%PDF-", anywhere = true },
    { name = "SQLite 3 database", magic = "SQLite format 3\0", anywhere = true },
    { name = "RIFF container (WAV/AVI/WebP)", magic = "RIFF", anywhere = true },
    { name = "Ogg stream", magic = "OggS", anywhere = true },
    { name = "Lua bytecode", magic = "\27Lua", anywhere = true },
    { name = "LuaJIT bytecode", magic = "\27LJ" },
    { name = "Mach-O 64-bit", magic = "\207\250\237\254", anywhere = true },
    { name = "Java class", magic = "\202\254\186\190", anywhere = true },
    { name = "WebAssembly module", magic = "\0asm", anywhere = true },
    { name = "ar archive", magic = "!<arch>\n", anywhere = true },
    { name = "tar archive", magic = "ustar", at = 257, anywhere = true },
    { name = "cpio archive (newc)", magic = "070701", anywhere = true },
    { name = "SquashFS image", magic = "hsqs", anywhere = true },
    { name = "U-Boot uImage", magic = "\39\5\25\86", anywhere = true },
    { name = "Flattened device tree", magic = "\208\13\254\237", anywhere = true },
}
local MAX_MAGIC_LENGTH = 16

local REGION_NOTES = {
    zeros = "zero padding",
    text = "printable text",
    structured = "low-entropy binary: headers or tables",
    dense = "code or mixed data",
    packed = "compressed or encrypted",
}

--------------------------------------------------------------------------------
-- 2. Byte helpers
--------------------------------------------------------------------------------
-- Lookup tables indexed by byte value: bytes that may appear inside a string
-- (space..tilde and tab), and bytes that count as text (those plus CR/LF).
local STRING_CHAR = ffi.new("uint8_t[256]")
local TEXT_CHAR = ffi.new("uint8_t[256]")
for value = 0x20, 0x7E do
    STRING_CHAR[value] = 1
    TEXT_CHAR[value] = 1
end
STRING_CHAR[0x09] = 1
TEXT_CHAR[0x09] = 1
TEXT_CHAR[0x0A] = 1
TEXT_CHAR[0x0D] = 1

local float_box = ffi.new("float[1]")
local double_box = ffi.new("double[1]")

local function as_bytes(data)
    return ffi.cast("const uint8_t *", data)
end

-- Unsigned integer of `width` bytes (1..4) at `position`, as a Lua number.
local function read_uint(bytes, position, width, big_endian)
    local value = 0
    for i = 0, width - 1 do
        local index = big_endian and (position + i) or (position + width - 1 - i)
        value = value * 256 + bytes[index]
    end
    return value
end

-- IEEE float of 4 or 8 bytes at `position`, in the host byte order.
local function read_float(bytes, position, width)
    local box = (width == 4) and float_box or double_box
    ffi.copy(box, bytes + position, width)
    return box[0]
end

local function hex_offset(value)
    return string.format("0x%08x", value)
end

--- Shannon entropy in bits per byte (0..8) of a 256-entry byte histogram.
function M.shannon_entropy(histogram, total)
    local entropy = 0
    for value = 0, 255 do
        local count = histogram[value]
        if count > 0 then
            local probability = count / total
            entropy = entropy - probability * math.log(probability) / LN2
        end
    end
    return entropy
end

local random_entropy_cache = {}

-- Entropy that uniformly random bytes are expected to measure in a sample of
-- `length` bytes. A short sample cannot show all 256 values evenly, so it reads
-- well below 8 (about 7.2 at 256 bytes); thresholds are scaled by this value.
-- Each byte value's count is Binomial(length, 1/256), so the expectation is
-- 256 * sum over k of P(count = k) * -(k/length) * log2(k/length).
local function random_entropy(length)
    local cached = random_entropy_cache[length]
    if cached then
        return cached
    end
    local hit = 1 / 256
    local probability = (1 - hit) ^ length
    local entropy = 0
    for count = 1, length do
        probability = probability * (length - count + 1) / count * hit / (1 - hit)
        local share = count / length
        entropy = entropy - 256 * probability * share * math.log(share) / LN2
        if count > length * hit and probability < 1e-18 then
            break
        end
    end
    random_entropy_cache[length] = entropy
    return entropy
end

--------------------------------------------------------------------------------
-- 3. Block classification and regions
--------------------------------------------------------------------------------
local block_histogram = ffi.new("uint32_t[256]")

--- Classify `length` bytes starting at `start`.
-- Returns class name, entropy and (for "zeros"/"fill") the repeated byte.
function M.classify_block(bytes, start, length)
    ffi.fill(block_histogram, ffi.sizeof(block_histogram))
    local text_count = 0
    for i = start, start + length - 1 do
        local value = bytes[i]
        block_histogram[value] = block_histogram[value] + 1
        text_count = text_count + TEXT_CHAR[value]
    end

    local first = bytes[start]
    if block_histogram[first] == length then
        return (first == 0) and "zeros" or "fill", 0, first
    end

    local entropy = M.shannon_entropy(block_histogram, length)
    local ceiling = random_entropy(length)
    if text_count >= length * TEXT_RATIO then
        return "text", entropy
    end
    if length >= MIN_PACKED_BLOCK and entropy >= PACKED_RATIO * ceiling then
        return "packed", entropy
    end
    if entropy < STRUCTURED_RATIO * ceiling then
        return "structured", entropy
    end
    return "dense", entropy
end

local function same_kind(region, class, fill_byte)
    return region.class == class and region.fill_byte == fill_byte
end

local function extend_region(region, size, entropy)
    region.entropy_sum = region.entropy_sum + entropy * size
    region.size = region.size + size
end

local function add_block(regions, offset, size, class, entropy, fill_byte)
    local last = regions[#regions]
    if last and same_kind(last, class, fill_byte) then
        extend_region(last, size, entropy)
        return
    end
    table.insert(regions, {
        offset = offset,
        size = size,
        class = class,
        fill_byte = fill_byte,
        entropy_sum = entropy * size,
    })
end

local function is_noise_island(region, block_size)
    return region.size <= block_size and (region.class == "structured" or region.class == "dense")
end

-- Fold single-block "structured"/"dense" islands into identical neighbours, so
-- one borderline block does not split a long region into three.
local function absorb_islands(regions, block_size)
    local merged = {}
    local index = 1
    while index <= #regions do
        local region = regions[index]
        local previous = merged[#merged]
        local following = regions[index + 1]
        if previous and following and is_noise_island(region, block_size)
            and same_kind(previous, following.class, following.fill_byte) then
            extend_region(previous, region.size, region.entropy_sum / region.size)
            extend_region(previous, following.size, following.entropy_sum / following.size)
            index = index + 2
        else
            table.insert(merged, region)
            index = index + 1
        end
    end
    return merged
end

local function finish_regions(regions, block_size)
    local merged = absorb_islands(regions, block_size)
    for _, region in ipairs(merged) do
        region.entropy = region.entropy_sum / region.size
        region.entropy_sum = nil
    end
    return merged
end

local function scan_blocks(state, bytes, length, chunk_offset)
    local block_size = state.block_size
    for start = 0, length - 1, block_size do
        local size = math.min(block_size, length - start)
        local class, entropy, fill_byte = M.classify_block(bytes, start, size)
        add_block(state.regions, chunk_offset + start, size, class, entropy, fill_byte)
    end
end

--------------------------------------------------------------------------------
-- 4. Capped result lists, signatures
--------------------------------------------------------------------------------
-- Keeps the total count but stores at most `keep_limit` items (0 = no cap), so a
-- file with a million strings cannot exhaust memory.
local function new_capped_list(keep_limit)
    return { count = 0, items = {}, keep_limit = keep_limit }
end

local function capped_add(list, item)
    list.count = list.count + 1
    if list.keep_limit == 0 or #list.items < list.keep_limit then
        table.insert(list.items, item)
    end
end

local function sort_by_offset(list)
    table.sort(list.items, function(left, right)
        return left.offset < right.offset
    end)
end

local function record_signature(state, signature, offset)
    capped_add(state.signatures, { offset = offset, name = signature.name })
    if offset == 0 and not state.file_type then
        state.file_type = signature.name
    end
end

local function find_embedded(state, signature, combined, combined_offset)
    local tail_length = #state.tail
    local magic_offset = signature.at or 0
    local position = combined:find(signature.magic, 1, true)
    while position do
        local start = combined_offset + position - 1 - magic_offset
        -- A hit lying wholly inside the carried-over tail was reported already.
        if position + #signature.magic - 1 > tail_length and start >= 0 then
            record_signature(state, signature, start)
        end
        position = combined:find(signature.magic, position + 1, true)
    end
end

local function scan_signatures(state, chunk, chunk_offset)
    local combined = state.tail .. chunk
    local combined_offset = chunk_offset - #state.tail
    for _, signature in ipairs(SIGNATURES) do
        local magic_offset = signature.at or 0
        if signature.anywhere then
            find_embedded(state, signature, combined, combined_offset)
        elseif chunk_offset == 0
            and chunk:sub(magic_offset + 1, magic_offset + #signature.magic) == signature.magic then
            record_signature(state, signature, 0)
        end
    end
    state.tail = combined:sub(-(MAX_MAGIC_LENGTH - 1))
end

--------------------------------------------------------------------------------
-- 5. Strings (ASCII and UTF-16LE)
--------------------------------------------------------------------------------
local function new_string_collector(kind, state)
    return {
        kind = kind,
        strings = state.strings,
        min_length = state.min_string,
        length = 0,
        start = 0,
        text = "",
    }
end

local function flush_run(collector)
    if collector.length >= collector.min_length then
        capped_add(collector.strings, {
            offset = collector.start,
            length = collector.length,
            kind = collector.kind,
            text = collector.text,
        })
    end
    collector.length = 0
end

local function push_char(collector, value, offset)
    if collector.length == 0 then
        collector.start = offset
        collector.text = ""
    end
    collector.length = collector.length + 1
    if #collector.text < MAX_STRING_TEXT then
        collector.text = collector.text .. string.char(value)
    end
end

-- Adds `count` string bytes found at `begin` to the current run. The text is
-- only copied out when the run can still qualify: most runs in binary data are
-- a byte or two long, and copying each one would dominate the scan time.
local function append_run(collector, bytes, begin, count, offset, may_continue)
    if collector.length == 0 then
        collector.start = offset
        collector.text = ""
    end
    collector.length = collector.length + count
    local room = MAX_STRING_TEXT - #collector.text
    if room > 0 and (may_continue or collector.length >= collector.min_length) then
        collector.text = collector.text .. ffi.string(bytes + begin, math.min(count, room))
    end
end

local function scan_ascii(collector, bytes, length, chunk_offset)
    local i = 0
    while i < length do
        local begin = i
        while i < length and STRING_CHAR[bytes[i]] ~= 0 do
            i = i + 1
        end
        if i > begin then
            -- A run touching the chunk end may continue in the next chunk.
            append_run(collector, bytes, begin, i - begin, chunk_offset + begin, i == length)
        end
        if i < length then
            flush_run(collector)
            i = i + 1
        end
    end
end

-- UTF-16LE text in the Basic Latin range is a printable byte followed by 0x00.
-- `pending` holds a printable byte still waiting for its zero high byte.
local function scan_utf16(collector, bytes, length, chunk_offset)
    for i = 0, length - 1 do
        local value = bytes[i]
        if collector.pending and value == 0 then
            push_char(collector, collector.pending, collector.pending_offset)
            collector.pending = nil
        else
            local printable = STRING_CHAR[value] ~= 0
            if collector.pending or not printable then
                flush_run(collector)
            end
            collector.pending = printable and value or nil
            collector.pending_offset = chunk_offset + i
        end
    end
end

--------------------------------------------------------------------------------
-- 6. Ascending u32 tables (likely offset tables)
--------------------------------------------------------------------------------
local function new_table_scanner(endian, state)
    return {
        endian = endian,
        tables = state.tables,
        file_size = state.size,
        run_length = 0,
    }
end

local function close_table_run(scanner)
    -- Entries of an offset table point at distinct items, so they are spaced at
    -- least a word apart on average; this drops plain counters such as 1,2,3,4.
    local spread = (scanner.run_length > 0) and (scanner.last - scanner.first) or 0
    if scanner.run_length >= MIN_TABLE_ENTRIES and spread >= scanner.run_length * 4 then
        capped_add(scanner.tables, {
            offset = scanner.run_start,
            count = scanner.run_length,
            endian = scanner.endian,
            first = scanner.first,
            last = scanner.last,
        })
    end
    scanner.run_length = 0
end

-- A run is consecutive u32 values that strictly ascend and all lie inside the
-- file: the usual shape of a table of offsets.
local function feed_table_value(scanner, value, offset)
    local in_file = value > 0 and value < scanner.file_size
    if scanner.run_length > 0 and in_file and value > scanner.last then
        scanner.run_length = scanner.run_length + 1
        scanner.last = value
        return
    end
    close_table_run(scanner)
    if in_file then
        scanner.run_start = offset
        scanner.run_length = 1
        scanner.first = value
        scanner.last = value
    end
end

local function scan_tables(state, bytes, length, chunk_offset)
    local little, big = state.table_le, state.table_be
    for position = 0, length - 4, 4 do
        local b0, b1, b2, b3 = bytes[position], bytes[position + 1], bytes[position + 2], bytes[position + 3]
        local offset = chunk_offset + position
        feed_table_value(little, b0 + b1 * 256 + b2 * 65536 + b3 * 16777216, offset)
        feed_table_value(big, b3 + b2 * 256 + b1 * 65536 + b0 * 16777216, offset)
    end
end

--------------------------------------------------------------------------------
-- 7. Whole-file scan
--------------------------------------------------------------------------------
local function new_scan_state(size, options)
    local block_size = options.block or DEFAULT_BLOCK_SIZE
    local limit = options.limit or DEFAULT_LIMIT
    local state = {
        size = size,
        block_size = block_size,
        -- A whole number of blocks per chunk keeps block boundaries aligned.
        chunk_size = block_size * math.max(1, math.floor(CHUNK_TARGET_SIZE / block_size)),
        min_string = options.min_string or DEFAULT_MIN_STRING,
        regions = {},
        signatures = new_capped_list(limit),
        strings = new_capped_list(limit),
        tables = new_capped_list(limit),
        tail = "",
    }
    state.ascii = new_string_collector("ascii", state)
    state.utf16 = new_string_collector("utf16le", state)
    state.table_le = new_table_scanner("LE", state)
    state.table_be = new_table_scanner("BE", state)
    return state
end

local function scan_chunk(state, chunk, chunk_offset)
    local bytes = as_bytes(chunk)
    local length = #chunk
    scan_blocks(state, bytes, length, chunk_offset)
    scan_signatures(state, chunk, chunk_offset)
    scan_ascii(state.ascii, bytes, length, chunk_offset)
    scan_utf16(state.utf16, bytes, length, chunk_offset)
    scan_tables(state, bytes, length, chunk_offset)
end

local function finish_scan(state)
    flush_run(state.ascii)
    flush_run(state.utf16)
    close_table_run(state.table_le)
    close_table_run(state.table_be)
    sort_by_offset(state.signatures)
    sort_by_offset(state.strings)
    sort_by_offset(state.tables)
    return {
        size = state.size,
        block_size = state.block_size,
        min_string = state.min_string,
        file_type = state.file_type,
        regions = finish_regions(state.regions, state.block_size),
        signatures = state.signatures,
        strings = state.strings,
        tables = state.tables,
    }
end

-- Large files take a while; a percentage on stderr shows the scan is alive and
-- leaves a last-known position if the process is interrupted.
local function report_progress(state, offset, progress_stream)
    if not progress_stream or state.size < PROGRESS_MIN_FILE_SIZE then
        return
    end
    local tenth = math.floor(offset * 10 / state.size)
    if tenth ~= state.progress_tenth then
        state.progress_tenth = tenth
        progress_stream:write(string.format("scanning: %d%%\n", tenth * 10))
        progress_stream:flush()
    end
end

--- Scan a whole open file. `options`: block, limit, min_string, progress (stream).
-- Returns the report table, or nil and an error message.
function M.scan_file(file, size, options)
    local state = new_scan_state(size, options)
    local offset = 0
    file:seek("set", 0)
    while offset < size do
        local chunk, read_err = file:read(state.chunk_size)
        if not chunk then
            return nil, string.format("read failed at offset %d of %d: %s",
                offset, size, read_err or "unexpected end of file")
        end
        scan_chunk(state, chunk, offset)
        offset = offset + #chunk
        report_progress(state, offset, options.progress)
    end
    return finish_scan(state)
end

--------------------------------------------------------------------------------
-- 8. Record probing: stride detection and field inference
--------------------------------------------------------------------------------
local function stride_score(bytes, length, stride)
    local matches = 0
    for i = 0, length - stride - 1 do
        if bytes[i] == bytes[i + stride] then
            matches = matches + 1
        end
    end
    return matches / (length - stride)
end

--- Find the record size of repeating data: the smallest shift at which the
-- bytes line up with themselves clearly better than at an average shift.
-- Returns stride and match ratio, or nil and a reason.
function M.find_stride(bytes, length)
    local max_stride = math.min(MAX_STRIDE, math.floor(length / 3))
    if max_stride < 2 then
        return nil, "window too small to detect a repeat"
    end
    local scores = {}
    local best = 0
    local sum = 0
    for stride = 2, max_stride do
        scores[stride] = stride_score(bytes, length, stride)
        best = math.max(best, scores[stride])
        sum = sum + scores[stride]
    end
    local mean = sum / (max_stride - 1)
    if best - mean < MIN_STRIDE_CONTRAST then
        return nil, "no dominant repeating record size"
    end
    for stride = 2, max_stride do
        if scores[stride] >= best - STRIDE_TOLERANCE then
            return stride, scores[stride]
        end
    end
end

-- Per byte column of the record grid: is it constant, and is it text-like
-- (every row printable or NUL, with at least one printable byte)?
local function column_stats(bytes, rows, stride, column)
    local first = bytes[column]
    local stats = { constant = true, value = first, textual = true }
    local printable_seen = false
    for row = 0, rows - 1 do
        local value = bytes[row * stride + column]
        if value ~= first then
            stats.constant = false
        end
        if STRING_CHAR[value] ~= 0 then
            printable_seen = true
        elseif value ~= 0 then
            stats.textual = false
        end
    end
    stats.textual = stats.textual and printable_seen
    stats.zero = stats.constant and first == 0
    return stats
end

local function fits(view, column, width)
    return column % width == 0 and column + width <= view.stride
end

local function match_text(view, column)
    local width = 0
    while column + width < view.stride and view.columns[column + width].textual do
        width = width + 1
    end
    if width < MIN_TEXT_FIELD then
        return nil
    end
    local sample = ffi.string(view.bytes + column, width):gsub("%z.*", "")
    return { width = width, type = "char[" .. width .. "]", note = string.format("%q", sample) }
end

local function match_constant(view, column, width)
    local parts = {}
    for i = 0, width - 1 do
        local stats = view.columns[column + i]
        if not stats.constant then
            return nil
        end
        parts[#parts + 1] = string.format("%02x", stats.value)
    end
    return { width = width, type = "const", note = "bytes " .. table.concat(parts, " ") }
end

local function plausible_float(value)
    if value ~= value or value == math.huge or value == -math.huge then
        return false
    end
    local magnitude = math.abs(value)
    return magnitude == 0 or (magnitude >= FLOAT_MIN_MAGNITUDE and magnitude <= FLOAT_MAX_MAGNITUDE)
end

local function match_float(view, column, width)
    -- Zero low bytes with only the top byte varying is a big-endian integer far
    -- more often than a float, so that pattern is left to match_integer.
    local low_bytes_vary = false
    for i = 0, width - 2 do
        low_bytes_vary = low_bytes_vary or not view.columns[column + i].zero
    end
    if not low_bytes_vary then
        return nil
    end
    local low, high = math.huge, -math.huge
    for row = 0, view.rows - 1 do
        local value = read_float(view.bytes, row * view.stride + column, width)
        if not plausible_float(value) then
            return nil
        end
        low = math.min(low, value)
        high = math.max(high, value)
    end
    local type_name = (width == 4) and "f32" or "f64"
    return { width = width, type = type_name, note = string.format("%.6g..%.6g", low, high) }
end

local function all_columns_vary(view, column, width)
    for i = 0, width - 1 do
        if view.columns[column + i].constant then
            return false
        end
    end
    return true
end

-- Little-endian integers keep their always-zero bytes at the high (last) end,
-- big-endian ones at the first end. Zero bytes at both ends (aligned offsets
-- such as 0x00001800) are read as little-endian unless the first end has more.
-- Returns "LE", "BE", "?" (every byte varies, order unknown) or nil when the
-- bytes do not look like one integer.
local function integer_byte_order(view, column, width)
    local zero_prefix = 0
    while zero_prefix < width and view.columns[column + zero_prefix].zero do
        zero_prefix = zero_prefix + 1
    end
    local zero_suffix = 0
    while zero_suffix < width and view.columns[column + width - 1 - zero_suffix].zero do
        zero_suffix = zero_suffix + 1
    end
    -- An always-zero byte between varying ones means two narrower fields.
    for i = zero_prefix, width - 1 - zero_suffix do
        if view.columns[column + i].zero then
            return nil
        end
    end
    if zero_prefix == 0 and zero_suffix == 0 then
        return all_columns_vary(view, column, width) and "?" or nil
    end
    return (zero_suffix >= zero_prefix) and "LE" or "BE"
end

local function integer_note(view, column, width, big_endian)
    local previous = read_uint(view.bytes, column, width, big_endian)
    local low, high = previous, previous
    local ascending = view.rows > 1
    local step = nil
    for row = 1, view.rows - 1 do
        local value = read_uint(view.bytes, row * view.stride + column, width, big_endian)
        low = math.min(low, value)
        high = math.max(high, value)
        ascending = ascending and value > previous
        local delta = value - previous
        if row == 1 then
            step = delta
        elseif step ~= delta then
            step = nil
        end
        previous = value
    end
    local note = string.format("0x%x..0x%x", low, high)
    if ascending and step then
        return note .. string.format(", sequence step +%d", step)
    end
    if ascending and width == 4 and high < view.file_size then
        return note .. ", ascending: possible file offsets"
    end
    if ascending then
        return note .. ", ascending"
    end
    return note
end

local function match_integer(view, column, width)
    local order = integer_byte_order(view, column, width)
    if not order then
        return nil
    end
    local note = integer_note(view, column, width, order == "BE")
    if order == "?" then
        note = note .. " (read as LE; every byte varies)"
    end
    return {
        width = width,
        type = string.format("u%d %s", width * 8, order),
        endian = (order ~= "?") and order or nil,
        note = note,
    }
end

local function match_byte(view, column)
    local stats = view.columns[column]
    if stats.constant then
        return match_constant(view, column, 1)
    end
    return { width = 1, type = "u8", note = integer_note(view, column, 1, false) }
end

local function match_wide(view, column, width)
    if not fits(view, column, width) then
        return nil
    end
    local field = match_constant(view, column, width)
    if not field and width >= 4 then
        field = match_float(view, column, width)
    end
    if not field and width <= 4 then
        field = match_integer(view, column, width)
    end
    return field
end

local function match_field(view, column)
    return match_text(view, column)
        or match_wide(view, column, 8)
        or match_wide(view, column, 4)
        or match_wide(view, column, 2)
        or match_byte(view, column)
end

local function dominant_byte_order(fields)
    local little, big = 0, 0
    for _, field in ipairs(fields) do
        if field.endian == "LE" then
            little = little + 1
        elseif field.endian == "BE" then
            big = big + 1
        end
    end
    if little == big then
        return "undetermined"
    end
    return (little > big) and "little-endian" or "big-endian"
end

--- Guess the fields of fixed-size records. `data` holds the records back to
-- back, `stride` is the record size, `file_size` bounds plausible offsets.
-- Returns a list of { offset, width, type, note } and the dominant byte order.
function M.infer_fields(data, stride, file_size)
    local bytes = as_bytes(data)
    local rows = math.floor(#data / stride)
    local view = { bytes = bytes, rows = rows, stride = stride, file_size = file_size, columns = {} }
    for column = 0, stride - 1 do
        view.columns[column] = column_stats(bytes, rows, stride, column)
    end
    local fields = {}
    local column = 0
    while column < stride do
        local field = match_field(view, column)
        field.offset = column
        table.insert(fields, field)
        column = column + field.width
    end
    return fields, dominant_byte_order(fields)
end

--- Probe a window of record data. `forced_stride` skips stride detection.
-- Returns { stride, score, rows, fields, byte_order }, or nil and a reason.
function M.probe(data, file_size, forced_stride)
    local stride, score = forced_stride, nil
    if not stride then
        stride, score = M.find_stride(as_bytes(data), #data)
        if not stride then
            return nil, score
        end
    end
    local rows = math.floor(#data / stride)
    if rows < 2 then
        return nil, string.format("stride %d needs at least %d bytes, window has %d",
            stride, stride * 2, #data)
    end
    local fields, byte_order = M.infer_fields(data, stride, file_size)
    return { stride = stride, score = score, rows = rows, fields = fields, byte_order = byte_order }
end

--------------------------------------------------------------------------------
-- 9. C struct overlay (ffi.cdef templates)
--------------------------------------------------------------------------------
local function type_kind(info)
    return bit.rshift(info, 28)
end

local function child_type(info)
    return bit.band(info, 0xFFFF)
end

-- Follow typedefs and attribute wrappers down to the real type.
local function resolve_type(type_id)
    local entry = ffi.typeinfo(type_id)
    local kind = type_kind(entry.info)
    while kind == CT_TYPEDEF or kind == CT_ATTRIB do
        type_id = child_type(entry.info)
        entry = ffi.typeinfo(type_id)
        kind = type_kind(entry.info)
    end
    return type_id, entry, kind
end

-- Named fields of a struct/union in declaration order. Members of anonymous
-- inner structs are reachable directly from the parent, so they are flattened.
local function struct_fields(struct_id, base_offset, fields)
    local sibling = ffi.typeinfo(struct_id).sib
    while sibling do
        local entry = ffi.typeinfo(sibling)
        local kind = type_kind(entry.info)
        -- An anonymous inner struct/union is listed as a nameless attribute entry.
        local is_member = kind == CT_FIELD or kind == CT_BITFIELD or kind == CT_ATTRIB
        if is_member and entry.name then
            table.insert(fields, {
                name = entry.name,
                offset = base_offset + entry.size,
                type_id = (kind == CT_FIELD) and child_type(entry.info) or nil,
            })
        elseif is_member then
            struct_fields(resolve_type(child_type(entry.info)), base_offset + entry.size, fields)
        end
        sibling = entry.sib
    end
    return fields
end

local function format_integer(value, size)
    if type(value) == "cdata" then
        local digits = tostring(value):gsub("U?LL$", "")
        return string.format("%s (0x%s)", digits, bit.tohex(value))
    end
    return string.format("%d (0x%s)", value, bit.tohex(value, size * 2))
end

local function format_number(value, entry)
    if bit.band(entry.info, CTF_BOOL) ~= 0 then
        return tostring(value)
    end
    if bit.band(entry.info, CTF_FP) ~= 0 then
        return string.format("%.9g", value)
    end
    return format_integer(value, entry.size)
end

local function format_byte_array(value, count)
    local text = ffi.string(value, count):gsub("%z+$", "")
    if #text > 0 and not text:find("[^\32-\126]") then
        return string.format("%q", text)
    end
    local parts = {}
    for i = 0, math.min(count, MAX_ARRAY_VALUES * 2) - 1 do
        parts[#parts + 1] = string.format("%02x", ffi.cast("const uint8_t *", value)[i])
    end
    local suffix = (count > MAX_ARRAY_VALUES * 2) and string.format(" ... (%d bytes)", count) or ""
    return table.concat(parts, " ") .. suffix
end

local describe_value

local function describe_struct(value, type_id, name, offset, rows)
    for _, field in ipairs(struct_fields(type_id, 0, {})) do
        local path = (name == "") and field.name or (name .. "." .. field.name)
        if field.type_id then
            describe_value(value[field.name], field.type_id, path, offset + field.offset, rows)
        else
            table.insert(rows, {
                name = path,
                offset = offset + field.offset,
                value = tostring(value[field.name]) .. " (bitfield)",
            })
        end
    end
end

local function describe_scalar_array(value, count, element_entry, name, offset, rows)
    if element_entry.size == 1 then
        table.insert(rows, { name = name, offset = offset, value = format_byte_array(value, count) })
        return
    end
    local parts = {}
    for i = 0, math.min(count, MAX_ARRAY_VALUES) - 1 do
        parts[#parts + 1] = format_number(value[i], element_entry)
    end
    local suffix = (count > MAX_ARRAY_VALUES) and string.format(" ... (%d total)", count) or ""
    table.insert(rows, { name = name, offset = offset, value = table.concat(parts, ", ") .. suffix })
end

local function describe_array(value, entry, name, offset, rows)
    local element_id, element_entry, element_kind = resolve_type(child_type(entry.info))
    local count = math.floor(entry.size / element_entry.size)
    if element_kind == CT_NUM then
        describe_scalar_array(value, count, element_entry, name, offset, rows)
        return
    end
    for i = 0, math.min(count, MAX_STRUCT_ELEMENTS) - 1 do
        local element_name = string.format("%s[%d]", name, i)
        describe_value(value[i], element_id, element_name, offset + i * element_entry.size, rows)
    end
    if count > MAX_STRUCT_ELEMENTS then
        local hidden = string.format("... %d more elements", count - MAX_STRUCT_ELEMENTS)
        table.insert(rows, { name = name, offset = offset, value = hidden })
    end
end

-- Appends { name, offset, value } rows describing `value` of type `type_id`.
describe_value = function(value, type_id, name, offset, rows)
    local resolved_id, entry, kind = resolve_type(type_id)
    if kind == CT_STRUCT then
        describe_struct(value, resolved_id, name, offset, rows)
    elseif kind == CT_ARRAY then
        describe_array(value, entry, name, offset, rows)
    else
        local text
        if kind == CT_NUM then
            text = format_number(value, entry)
        elseif kind == CT_ENUM then
            text = format_integer(tonumber(value), entry.size) .. " (enum)"
        elseif kind == CT_PTR then
            text = string.format("pointer 0x%x", tonumber(ffi.cast("uintptr_t", value)))
        else
            text = tostring(value)
        end
        table.insert(rows, { name = name, offset = offset, value = text })
    end
end

--- Pick the type to overlay when --type is not given: the last struct tag or
-- typedef name declared in the template. Returns the name, or nil.
function M.guess_type_name(declarations)
    local best_position, best_name = 0, nil
    for position, name in declarations:gmatch("()}%s*([%a_][%w_]*)%s*;") do
        if position > best_position then
            best_position, best_name = position, name
        end
    end
    for position, name in declarations:gmatch("()struct%s+([%a_][%w_]*)%s*{") do
        if position > best_position then
            best_position, best_name = position, "struct " .. name
        end
    end
    return best_name
end

--- Declare `declarations` (C source for ffi.cdef) and resolve `type_name`.
-- Returns the ctype and its size, or nil and an error message.
function M.load_struct_type(declarations, type_name)
    local declared, cdef_err = pcall(ffi.cdef, declarations)
    if not declared then
        return nil, "invalid C declarations: " .. tostring(cdef_err)
    end
    type_name = type_name or M.guess_type_name(declarations)
    if not type_name then
        return nil, "no struct found in the template; name one with --type"
    end
    local resolved, ctype = pcall(ffi.typeof, type_name)
    if not resolved then
        return nil, string.format("unknown type '%s': %s", type_name, tostring(ctype))
    end
    local _, _, kind = resolve_type(tonumber(ctype))
    if kind ~= CT_STRUCT then
        return nil, string.format("type '%s' is not a struct or union", type_name)
    end
    return ctype, ffi.sizeof(ctype), type_name
end

--- Overlay `count` consecutive structs of `ctype` on `data` (bytes at
-- `base_offset` in the file). Returns one list of field rows per struct.
function M.overlay_struct(ctype, data, base_offset, count)
    local size = ffi.sizeof(ctype)
    local buffer = ffi.new("uint8_t[?]", size * count)
    ffi.copy(buffer, data, size * count)
    local pointer = ffi.cast(ffi.typeof("$ *", ctype), buffer)
    local instances = {}
    for index = 0, count - 1 do
        local rows = {}
        describe_value(pointer[index], tonumber(ctype), "", base_offset + index * size, rows)
        table.insert(instances, { offset = base_offset + index * size, fields = rows })
    end
    return instances
end

--------------------------------------------------------------------------------
-- 10. Renderers (pure: data in, string out)
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
-- 11. File access
--------------------------------------------------------------------------------
--- Open `path` for binary reading. Returns file and size, or nil and an error.
function M.open_input(path)
    -- "rb" matters on Windows: text mode would translate CRLF and stop at 0x1A.
    local file, open_err = io.open(path, "rb")
    if not file then
        return nil, "cannot open " .. tostring(open_err)
    end
    local size = file:seek("end")
    -- A directory opens on POSIX but reports no usable size.
    if not size or size >= MAX_REGULAR_FILE_SIZE then
        file:close()
        return nil, path .. ": not a regular file (is it a directory?)"
    end
    if size == 0 then
        file:close()
        return nil, path .. " is empty (0 bytes): nothing to analyse"
    end
    return file, size
end

-- Read up to `length` bytes at `offset`. Returns the data, or nil and an error.
local function read_window(file, size, offset, length)
    if offset >= size then
        return nil, string.format("offset 0x%x is beyond the end of the file (%d bytes)", offset, size)
    end
    file:seek("set", offset)
    local data, read_err = file:read(math.min(length, size - offset))
    if not data then
        return nil, string.format("read failed at offset 0x%x: %s", offset,
            read_err or "unexpected end of file")
    end
    return data
end

local function read_text_file(path)
    local file, open_err = io.open(path, "rb")
    if not file then
        return nil, "cannot open template " .. tostring(open_err)
    end
    local text = file:read("*a")
    file:close()
    if not text then
        return nil, "cannot read template " .. path
    end
    return text
end

--------------------------------------------------------------------------------
-- 12. Command line
--------------------------------------------------------------------------------
local USAGE = [[
ffi_binscope - explore the structure of an unknown binary file

Usage: luajit ffi_binscope.lua <file> [mode] [options]

Modes (default: whole-file report):
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
  --json                Print the report or probe result as JSON
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
    if modes > 1 then
        return nil, "choose only one of --probe, --hexdump, --struct"
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
    return run_report(file, size, options)
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
-- 13. Entry point
--------------------------------------------------------------------------------
-- Run only when executed as a script; require("ffi_binscope") returns the module.
local script_name = arg and arg[0] and arg[0]:gsub("\\", "/"):match("([^/]+)$")
if script_name == "ffi_binscope.lua" then
    os.exit(M.main(arg))
end

return M
