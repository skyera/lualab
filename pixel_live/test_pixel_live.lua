-- =============================================================================
-- Unit & Integration Tests for Pixel live
-- =============================================================================

local board_mod = require("./board")
local ws = require("./ws")

-- =============================================================================
-- Board Tests
-- =============================================================================

local function test_board_creation_and_validation()
    local board = assert(board_mod.new(4, 4))
    assert(board.width == 4)
    assert(board.height == 4)
    assert(board:get(0, 0) == 0)
    assert(board:get(3, 3) == 0)

    local bad, err = board_mod.new(0, 4)
    assert(bad == nil)
    assert(type(err) == "string")

    local bad_frac, err_frac = board_mod.new(4, 2.5)
    assert(bad_frac == nil)
    assert(type(err_frac) == "string")
end

local function test_board_set_get_and_bounds()
    local board = assert(board_mod.new(4, 4))
    assert(board:set(1, 2, 7))
    assert(board:get(1, 2) == 7)

    local ok, err = board:set(-1, 0, 1)
    assert(ok == nil)
    assert(type(err) == "string")

    local out, out_err = board:get(4, 0)
    assert(out == nil)
    assert(type(out_err) == "string")

    local bad_color, color_err = board:set(0, 0, 16)
    assert(bad_color == nil)
    assert(type(color_err) == "string")
end

local function test_board_clear_and_to_hex()
    local board = assert(board_mod.new(2, 2))
    assert(board:set(0, 0, 1))
    assert(board:set(1, 0, 10))
    assert(board:set(1, 1, 15))
    assert(board:to_hex() == "1a0f")

    board:clear()
    assert(board:to_hex() == "0000")
end

-- =============================================================================
-- WebSocket Codec Tests
-- =============================================================================

local function test_ws_accept_key_rfc_vector()
    local accept = assert(ws.compute_accept_key("dGhlIHNhbXBsZSBub25jZQ=="))
    assert(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

    local bad, err = ws.compute_accept_key("")
    assert(bad == nil)
    assert(type(err) == "string")
end

local function test_ws_decode_masked_rfc_example()
    -- Official RFC 6455 Section 5.7 masked "Hello" frame
    local raw = string.char(
        0x81, 0x85,
        0x37, 0xfa, 0x21, 0x3d,
        0x7f, 0x9f, 0x4d, 0x51, 0x58
    )

    -- Partial TCP chunk must return nil, nil (wait for more bytes)
    local partial, partial_err = ws.decode_frame(raw:sub(1, 5))
    assert(partial == nil)
    assert(partial_err == nil)

    local frame, consumed = ws.decode_frame(raw)
    assert(frame ~= nil)
    assert(frame.fin == true)
    assert(frame.masked == true)
    assert(frame.opcode == ws.OP_TEXT)
    assert(frame.payload == "Hello")
    assert(consumed == #raw)
end

local function test_ws_encode_and_coalesced_frames()
    local first = ws.encode_frame("ping", ws.OP_PING)
    local medium_text = string.rep("a", 500)
    local second = ws.encode_frame(medium_text, ws.OP_TEXT)
    local stream = first .. second

    local frame1, used1 = ws.decode_frame(stream)
    assert(frame1.opcode == ws.OP_PING)
    assert(frame1.payload == "ping")
    assert(frame1.masked == false)

    local frame2, used2 = ws.decode_frame(stream:sub(used1 + 1))
    assert(frame2.opcode == ws.OP_TEXT)
    assert(frame2.payload == medium_text)
    assert(used1 + used2 == #stream)
end

-- =============================================================================
-- Runner
-- =============================================================================

local function run_all()
    test_board_creation_and_validation()
    test_board_set_get_and_bounds()
    test_board_clear_and_to_hex()
    test_ws_accept_key_rfc_vector()
    test_ws_decode_masked_rfc_example()
    test_ws_encode_and_coalesced_frames()
    print("All pixel_live tests passed.")
end

run_all()
