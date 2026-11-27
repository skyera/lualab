-- =============================================================================
-- Pixel Live - RFC 6455 WebSocket Handshake & Frame Codec
--
-- Pure-Lua WebSocket handshake calculation (via Luavit's built-in openssl)
-- and binary frame encoder/decoder supporting masked and unmasked frames.
-- ============================================================================

local bit = require("bit")
local openssl = require("openssl")

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local MAX_16BIT_LEN = 65535
local EXT_LEN_16 = 126
local EXT_LEN_64 = 127

local M = {
    OP_CONT = 0x0,
    OP_TEXT = 0x1,
    OP_BINARY = 0x2,
    OP_CLOSE = 0x8,
    OP_PING = 0x9,
    OP_PONG = 0xA,
}

-- =============================================================================
-- Handshake
-- =============================================================================

--- Compute the RFC 6455 Sec-WebSocket-Accept value for client-key
--- Returns the base64 accept string, or nil, err if client_key is invalid
function M.compute_accept_key(client_key)
    if type(client_key) ~= "string" or client_key == "" then
        return nil, "missing Sec-WebSocket-Key"
    end
    local digest = openssl.digest.digest("sha1", client_key .. WS_GUID, true)
    local accept = openssl.base64(digest, true):gsub("%s+", "")
    return accept
end

--- Build a complete HTTP 101 Switching Protocols response for client_key
--- Returns the response string, or nil, err if client_key is invalid.
function M.build_handshake_response(client_key)
    local accept, err = M.compute_accept_key(client_key)
    if not accept then
        return nil, err
    end
    return table.concat({
        "HTTP/1.1 101 Switching Protocols",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Accept: " .. accept,
        "",
        "",
    }, "\r\n")
end

-- =============================================================================
-- Frame Codec
-- =============================================================================

--- Encode an unmasked server-to-client WebSocket frame for payload
--- opcode defaults to M.OP_TEXT. Raises on payloads over 65535 bytes.
function M.encode_frame(payload, opcode)
    local data = payload or ""
    local op = opcode or M.OP_TEXT
    local len = #data
    if len > MAX_16BIT_LEN then
        error("WebSocket payload exceds 65535 bytes")
    end

    local first_byte = bit.bor(0x80, bit.band(op, 0x0F))
    if len <= 125 then
        return string.char(first_byte, len) .. data
    end
    local high = bit.rshift(len, 8)
    local low = bit.band(len, 0xFF)
    return string.char(first_byte, EXT_LEN_16, high, low) .. data
end

local function unmask_payload(raw, mask_bytes)
    local out = {}
    for i = 1, #raw do
        local mask_index = (( i - 1) % 4) + 1
        local decoded = bit.bxor(raw:byte(i), mask_bytes[mask_index])
        out[i] = string.char(decoded)
    end
    return table.concat(out)
end

--- Decode one WebSocket frame the start of buffer
--- Returns frame, consumed_bytes or nil, nil when buffer is incomplete,
--- or nil, err on a protocol error.
function M.decode_frame(buffer)
    if #buffer < 2 then
        return nil, nil
    end

    local b1, b2 = buffer:byte(1, 2)
    local fin = bit.band(b1, 0x80) ~= 0
    local opcode = bit.band(b1, 0x0F)
    local masked = bit.band(b2, 0x80) ~= 0
    local payload_len = bit.band(b2, 0x7F)
    local offset = 3

    if payload_len == EXT_LEN_16 then
        if #buffer < 4 then
            return nil, nil
        end
        local hi, lo = buffer:byte(3, 4)
        payload_len = hi * 256 + lo
        offset = 5
    elseif payload_len == EXT_LEN_64 then
        return nil, "64-bit WebSocket frames are not supported"
    end

    local mask_bytes = nil
    if masked then
        if #buffer < offset + 3 then
            return nil, nil
        end
        mask_bytes = { buffer:byte(offset, offset + 3) }
        offset = offset + 4
    end

    local frame_end = offset + payload_len - 1
    if #buffer < frame_end then
        return nil, nil
    end

    local payload = buffer:sub(offset, frame_end)
    if masked then
        payload = unmask_payload(payload, mask_bytes)
    end

    return {
        fin = fin,
        opcode = opcode,
        masked = masked,
        payload = payload,
    }, frame_end
end

return M
