--------------------------------------------------------------------------------
-- binscope_scan.lua
-- Whole-file scanner for ffi_binscope (LuaJIT FFI, Windows & POSIX).
--
-- Reads a file in fixed-size chunks in binary mode and reports known
-- signatures (also embedded ones), an entropy map merged into regions
-- (zeros / fill / text / structured / dense / packed), ascending u32 tables
-- and ASCII / UTF-16LE strings. Also holds the byte-level helpers and file
-- access shared by the other binscope modules.
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

local M = {}

--------------------------------------------------------------------------------
-- 1. Constants
--------------------------------------------------------------------------------
local LN2 = math.log(2)
local CHUNK_TARGET_SIZE = 65536
local MAX_REGULAR_FILE_SIZE = 2 ^ 62
local PROGRESS_MIN_FILE_SIZE = 32 * 1024 * 1024

local DEFAULT_BLOCK_SIZE = 1024
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

local HOST_LITTLE_ENDIAN = ffi.abi("le")
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

-- True when the 8 bytes at `position` are a NaN or infinity (exponent bits all
-- set), judged from the raw bytes in the host byte order.
local function double_is_special(bytes, position)
    local top = HOST_LITTLE_ENDIAN and bytes[position + 7] or bytes[position]
    local next_byte = HOST_LITTLE_ENDIAN and bytes[position + 6] or bytes[position + 1]
    return bit.band(top, 0x7F) == 0x7F and bit.band(next_byte, 0xF0) == 0xF0
end

-- IEEE float of 4 or 8 bytes at `position`, in the host byte order; nil for a
-- NaN or infinity. LuaJIT stores every Lua value inside the NaN space of a
-- double, so loading an arbitrary NaN bit pattern from file bytes would yield
-- a corrupt value (a "number" that is really a table or function reference).
-- Doubles are therefore screened by their bytes before being loaded; 4-byte
-- floats are safe because widening them to double normalises the NaN.
local function read_float(bytes, position, width)
    if width == 8 and double_is_special(bytes, position) then
        return nil
    end
    local box = (width == 4) and float_box or double_box
    ffi.copy(box, bytes + position, width)
    local value = box[0]
    if value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
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
-- 8. File access
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
-- 9. Helpers shared with the other binscope modules
--------------------------------------------------------------------------------
M.STRING_CHAR = STRING_CHAR
M.as_bytes = as_bytes
M.read_uint = read_uint
M.read_float = read_float
M.same_kind = same_kind
M.read_window = read_window
M.read_text_file = read_text_file
M.hex_offset = hex_offset

return M
