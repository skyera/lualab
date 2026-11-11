--------------------------------------------------------------------------------
-- binscope_struct.lua
-- C struct overlay for ffi_binscope.
--
-- Declares a user-supplied C struct through ffi.cdef, lays it over bytes
-- read from a file and lists every member with its offset and value, using
-- LuaJIT's ctype information to walk nested structs, unions and arrays.
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")
local scan = require("binscope_scan")

local read_float = scan.read_float

local M = {}

--------------------------------------------------------------------------------
-- 1. Constants
--------------------------------------------------------------------------------
local MAX_ARRAY_VALUES = 8
local MAX_STRUCT_ELEMENTS = 4

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

--------------------------------------------------------------------------------
-- 2. C struct overlay (ffi.cdef templates)
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

local function is_float_type(entry)
    return bit.band(entry.info, CTF_FP) ~= 0
end

-- Text for the floating-point number stored at `address`. It is read through
-- read_float so that a NaN in the file cannot become a corrupt Lua value.
local function format_float_at(address, size)
    if size ~= 4 and size ~= 8 then
        return string.format("(%d-byte float not shown)", size)
    end
    local value = read_float(ffi.cast("const uint8_t *", address), 0, size)
    return value and string.format("%.9g", value) or "nan or inf"
end

local function format_number(value, entry)
    if bit.band(entry.info, CTF_BOOL) ~= 0 then
        return tostring(value)
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

-- Describes one struct member. A floating-point member is formatted from its
-- address, never by indexing the struct, so a NaN in the file stays harmless.
local function describe_member(value, field, path, offset, rows)
    local _, entry, kind = resolve_type(field.type_id)
    if kind == CT_NUM and is_float_type(entry) then
        local address = ffi.cast("const uint8_t *", value) + field.offset
        table.insert(rows, { name = path, offset = offset, value = format_float_at(address, entry.size) })
        return
    end
    describe_value(value[field.name], field.type_id, path, offset, rows)
end

local function describe_struct(value, type_id, name, offset, rows)
    for _, field in ipairs(struct_fields(type_id, 0, {})) do
        local path = (name == "") and field.name or (name .. "." .. field.name)
        if field.type_id then
            describe_member(value, field, path, offset + field.offset, rows)
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
        if is_float_type(element_entry) then
            parts[#parts + 1] = format_float_at(value + i, element_entry.size)
        else
            parts[#parts + 1] = format_number(value[i], element_entry)
        end
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

return M
