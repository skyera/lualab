-- =============================================================================
-- Unit & Integration Tests for Pixel live
-- =============================================================================

local board_mod = require("./board")

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
-- Runner
-- =============================================================================

local function run_all()
    test_board_creation_and_validation()
    test_board_set_get_and_bounds()
    test_board_clear_and_to_hex()
    print("All pixel_live tests passed.")
end

run_all()
