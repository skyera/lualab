--------------------------------------------------------------------------------
-- binscope_records.lua
-- Fixed-size record analysis for ffi_binscope.
--
-- Finds the record size of repeating data, guesses the type of each field
-- (integers and their byte order, floats, text, constants), and locates
-- record tables inside a block of bytes without being told where they are.
--------------------------------------------------------------------------------

local ffi = require("ffi")
local scan = require("binscope_scan")

local STRING_CHAR = scan.STRING_CHAR
local as_bytes = scan.as_bytes
local read_uint = scan.read_uint
local read_float = scan.read_float

local M = {}

--------------------------------------------------------------------------------
-- 1. Constants
--------------------------------------------------------------------------------
local MAX_STRIDE = 256
local MIN_STRIDE_CONTRAST = 0.15
local STRIDE_TOLERANCE = 0.02
local DIVISOR_TOLERANCE = 0.08
local MIN_TEXT_FIELD = 4
local FLOAT_MIN_MAGNITUDE = 1e-4
local FLOAT_MAX_MAGNITUDE = 1e9

-- Automatic table search: window slid over the data, and the limits that keep
-- the search quick on large files.
local TABLE_WINDOW = 256
local TABLE_WINDOW_STEP = 128
local MIN_TABLE_ROWS = 8
local MIN_APPROXIMATE_ROWS = 16
-- Share of a record that must decode into recognisable fields: the normal bar,
-- and the stricter one used inside code-like data where chance repeats occur.
local TABLE_CONFIDENCE = 0.5
local STRICT_TABLE_CONFIDENCE = 0.75
local PHASE_SAMPLE_ROWS = 32
-- How many bytes of cleaner decoding another start needs to beat the preferred one.
local PREFERRED_START_MARGIN = 1
local MAX_TABLE_ROWS = 4096

--------------------------------------------------------------------------------
-- 2. Record probing: stride detection and field inference
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

-- Records repeat at every multiple of their size, and in a short window a
-- multiple can score a little higher by chance. Prefer a divisor of `stride`
-- that lines up nearly as well: it is the real record size.
local function smallest_period(scores, stride)
    for divisor = 2, math.floor(stride / 2) do
        if stride % divisor == 0 and scores[divisor] >= scores[stride] - DIVISOR_TOLERANCE then
            return divisor
        end
    end
    return stride
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
            stride = smallest_period(scores, stride)
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
    if not value then
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
    -- The lowest byte of a changing number changes most; if it is a fixed
    -- non-zero value instead, this is a constant tag followed by a narrower field.
    local little = zero_suffix >= zero_prefix
    local lowest = little and (column + zero_prefix) or (column + width - 1 - zero_suffix)
    if view.columns[lowest].constant then
        return nil
    end
    return little and "LE" or "BE"
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
        return note .. string.format(", sequence step +%d", step), low, high, true
    end
    if ascending and width == 4 and high < view.file_size then
        return note .. ", ascending: possible file offsets", low, high, true
    end
    if ascending then
        return note .. ", ascending", low, high, true
    end
    return note, low, high, false
end

local function match_integer(view, column, width)
    local order = integer_byte_order(view, column, width)
    if not order then
        return nil
    end
    local note, low, high, ascending = integer_note(view, column, width, order == "BE")
    if order == "?" then
        note = note .. " (read as LE; every byte varies)"
    end
    return {
        width = width,
        type = string.format("u%d %s", width * 8, order),
        endian = (order ~= "?") and order or nil,
        note = note,
        low = low,
        high = high,
        ascending = ascending,
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
-- 3. Table discovery: locate record tables without being told where they are
--------------------------------------------------------------------------------
-- Two windows over the same table can report its record size and a multiple
-- of it. Returns the smaller size when one divides the other, else nil.
local function common_stride(left, right)
    local small, large = math.min(left, right), math.max(left, right)
    return (large % small == 0) and small or nil
end

-- Slide a window over the data and note where a record size shows up.
-- Neighbouring windows that agree are joined into one candidate.
local function stride_candidates(bytes, length)
    local candidates = {}
    local window = math.min(TABLE_WINDOW, length)
    for start = 0, length - window, TABLE_WINDOW_STEP do
        local stride = M.find_stride(bytes + start, window)
        local last = candidates[#candidates]
        local shared = stride and last and start <= last.finish and common_stride(stride, last.stride)
        if shared then
            last.stride = shared
            last.finish = start + window
        elseif stride then
            candidates[#candidates + 1] = { start = start, finish = start + window, stride = stride }
        end
    end
    return candidates
end

-- For each position modulo `stride`, the byte value that never changes over
-- [first, last), or false when it varies.
local function constant_columns(bytes, first, last, stride)
    local columns = {}
    for position = first, last - 1 do
        local phase = position % stride
        local value = bytes[position]
        if position < first + stride then
            columns[phase] = value
        elseif columns[phase] ~= value then
            columns[phase] = false
        end
    end
    return columns
end

local function matches_column(columns, stride, bytes, position)
    local expected = columns[position % stride]
    return not expected or expected == bytes[position]
end

-- Widen [first, last) for as long as the constant columns keep their values:
-- the table ends where a byte that never changed inside it changes.
local function grow_extent(bytes, length, columns, stride, first, last)
    while first > 0 and matches_column(columns, stride, bytes, first - 1) do
        first = first - 1
    end
    while last < length and matches_column(columns, stride, bytes, last) do
        last = last + 1
    end
    return first, last
end

local function count_constant(columns, stride)
    local count = 0
    for phase = 0, stride - 1 do
        if columns[phase] then
            count = count + 1
        end
    end
    return count
end

-- True when every constant column other than `ignored_phase` still holds in
-- the record-sized stretch starting at `row_start`.
local function others_hold(bytes, length, columns, stride, row_start, ignored_phase)
    if row_start < 0 or row_start + stride > length then
        return false
    end
    for position = row_start, row_start + stride - 1 do
        local phase = position % stride
        local expected = columns[phase]
        if phase ~= ignored_phase and expected and expected ~= bytes[position] then
            return false
        end
    end
    return true
end

-- Growth stopped at `stop_phase`. A real table boundary breaks the constant
-- columns together; if the others carry on unchanged past the stop, that one
-- byte was only constant in the core (a slowly changing value such as a float
-- exponent). Stop trusting it. Returns true when a column was released.
local function release_soft_column(bytes, length, columns, stride, row_start, stop_phase)
    if not others_hold(bytes, length, columns, stride, row_start, stop_phase) then
        return false
    end
    columns[stop_phase] = false
    return true
end

-- Grow the extent from the core. Where growth stops well inside the windows
-- that detected the record size, check whether it hit a real boundary or a
-- soft column, and grow again after releasing a soft one.
-- Returns first, last and how many constant columns are left.
local function settle_extent(bytes, length, candidate, columns, core_first, core_last)
    local stride = candidate.stride
    local first, last
    local released
    repeat
        first, last = grow_extent(bytes, length, columns, stride, core_first, core_last)
        released = false
        if first > candidate.start + TABLE_WINDOW_STEP then
            released = release_soft_column(bytes, length, columns, stride, first - stride,
                (first - 1) % stride)
        end
        if last < candidate.finish - TABLE_WINDOW_STEP then
            released = release_soft_column(bytes, length, columns, stride, last, last % stride)
                or released
        end
    until not released
    return first, last, count_constant(columns, stride)
end

local function is_confident(field)
    return field.type ~= "u8" and not field.type:find("?", 1, true)
end

local function confident_bytes(fields)
    local total = 0
    for _, field in ipairs(fields) do
        if is_confident(field) then
            total = total + field.width
        end
    end
    return total
end

local function sample_fields(bytes, start, last, stride, file_size, max_rows)
    local rows = math.min(max_rows, math.floor((last - start) / stride))
    return M.infer_fields(ffi.string(bytes + start, rows * stride), stride, file_size)
end

-- Where a record most plausibly begins when several starts explain the data
-- equally well: at the first non-zero byte, moved back to a word boundary
-- (records usually start aligned, and zero bytes before them are padding).
local function preferred_start(bytes, first, last, stride)
    local position = first
    while position < last and bytes[position] == 0 do
        position = position + 1
    end
    local alignment = (stride % 4 == 0) and 4 or ((stride % 2 == 0) and 2 or 1)
    local aligned = position - position % alignment
    return (aligned >= first) and aligned or position
end

-- A repeating pattern looks the same from any starting byte, so try each start
-- within one record and keep the one whose fields decode most cleanly. The
-- preferred start wins unless another start is clearly better, because field
-- quality alone cannot tell a record from the same record rotated.
local function choose_start(bytes, first, last, stride, file_size)
    local preferred = preferred_start(bytes, first, last, stride)
    local base = math.max(first, preferred - stride + 1)
    local best_start, best_score, preferred_score = base, -1, -1
    for candidate = base, math.min(base + stride, last - 2 * stride) - 1 do
        local fields = sample_fields(bytes, candidate, last, stride, file_size, PHASE_SAMPLE_ROWS)
        -- Half a point for a recognisable first field: records rarely open
        -- with their least regular bytes.
        local score = confident_bytes(fields) + (is_confident(fields[1]) and 0.5 or 0)
        if score > best_score then
            best_start, best_score = candidate, score
        end
        if candidate == preferred then
            preferred_score = score
        end
    end
    if preferred_score >= best_score - PREFERRED_START_MARGIN then
        return preferred, preferred_score
    end
    return best_start, best_score
end

local function row_is_zero(bytes, start, stride)
    for i = 0, stride - 1 do
        if bytes[start + i] ~= 0 then
            return false
        end
    end
    return true
end

-- Whole records between start and last, without trailing all-zero rows (those
-- are padding after the table, not records).
local function count_rows(bytes, start, last, stride)
    local rows = math.floor((last - start) / stride)
    while rows > 0 and row_is_zero(bytes, start + (rows - 1) * stride, stride) do
        rows = rows - 1
    end
    return rows
end

-- Turn a window-level candidate into a table with exact start, row count and
-- fields. Returns nil when the candidate does not hold up. `strict` demands
-- constant bytes and cleaner fields (see STRICT_TABLE_CONFIDENCE).
local function locate_table(bytes, length, candidate, file_size, strict)
    local stride = candidate.stride
    -- The middle of the candidate is the part most surely inside the table.
    local quarter = math.floor((candidate.finish - candidate.start) / 4)
    local first, last = candidate.start + quarter, candidate.finish - quarter
    if last - first < 3 * stride then
        first, last = candidate.start, candidate.finish
    end
    local columns = constant_columns(bytes, first, last, stride)
    local grown_first, grown_last, constant_count = settle_extent(bytes, length, candidate, columns,
        first, last)
    -- With no constant byte there is nothing to mark where the table ends, so
    -- only the sure middle part is reported.
    local approximate = constant_count == 0
    if not approximate then
        first, last = grown_first, grown_last
    end
    local start, score = choose_start(bytes, first, last, stride, file_size)
    local rows = count_rows(bytes, start, last, stride)
    local confidence = strict and STRICT_TABLE_CONFIDENCE or TABLE_CONFIDENCE
    -- A table without firm bounds needs more rows before it is believed.
    local needed_rows = approximate and MIN_APPROXIMATE_ROWS or MIN_TABLE_ROWS
    if rows < needed_rows or score < stride * confidence or (strict and approximate) then
        return nil
    end
    local fields, byte_order = sample_fields(bytes, start, start + rows * stride, stride,
        file_size, MAX_TABLE_ROWS)
    return {
        offset = start,
        stride = stride,
        rows = rows,
        fields = fields,
        byte_order = byte_order,
        approximate = approximate,
    }
end

--- Find tables of fixed-size records in `data`, which was read at
-- `base_offset` of a file of `file_size` bytes. `strict` raises the bar for
-- accepting a table. Returns a list of
-- { offset, stride, rows, fields, byte_order, approximate }.
function M.find_tables(data, base_offset, file_size, strict)
    local bytes = as_bytes(data)
    local tables = {}
    local covered = 0
    for _, candidate in ipairs(stride_candidates(bytes, #data)) do
        local found = candidate.finish > covered
            and locate_table(bytes, #data, candidate, file_size, strict)
        if found and found.offset >= covered then
            covered = found.offset + found.rows * found.stride
            found.offset = base_offset + found.offset
            tables[#tables + 1] = found
        end
    end
    return tables
end

return M
