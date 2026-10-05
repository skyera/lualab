#!/usr/bin/env luajit
--[[
    test_ffi_enigma.lua
    Unit, integration, and historical cryptographic test suite for ffi_enigma.lua.
]]

print("=== Running Unit Tests for ffi_enigma.lua (Enigma) ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "luajit ffi_enigma.lua --help",
        expect = "Enigma Cipher Machine (Enigma I / M3) - LuaJIT FFI Simulator"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "luajit ffi_enigma.lua --test",
        expect = "ALL ENIGMA TESTS PASSED SUCCESSFULLY!"
    },
    {
        name = "Snapshot non-interactive render (--snapshot)",
        cmd = "luajit ffi_enigma.lua --snapshot",
        expect = "ENIGMA CIPHER MACHINE"
    },
    {
        name = "ASCII snapshot render (--snapshot --ascii)",
        cmd = "luajit ffi_enigma.lua --snapshot --ascii",
        expect = "+================================================================+"
    },
    {
        name = "Launcher basic encryption (enigma.lua 'AAAAA')",
        cmd = "luajit enigma.lua 'AAAAA'",
        expect = "BDZGO"
    },
    {
        name = "Piped stdin reciprocal decryption (echo 'BDZGO' | luajit enigma.lua)",
        cmd = "echo 'BDZGO' | luajit enigma.lua",
        expect = "AAAAA"
    },
    {
        name = "Complex configuration with Rotors II, IV, V, Rings BUL, Pos WXY, UKW-C, Plugs",
        cmd = "luajit enigma.lua --rotors II,IV,V --rings BUL --pos WXY --reflector UKW-C --plugs 'AV BS CG DL FU HZ IN KM OW RX' 'THE ENIGMA MACHINE'",
        expect = "QGU ORMPSK FNIKFHB"
    },
    {
        name = "Piped decryption with complex configuration",
        cmd = "echo 'QGU ORMPSK FNIKFHB' | luajit enigma.lua --rotors II,IV,V --rings BUL --pos WXY --reflector UKW-C --plugs 'AV BS CG DL FU HZ IN KM OW RX'",
        expect = "THE ENIGMA MACHINE"
    }
}

local passed = 0
local total_tests = #tests

for i, t in ipairs(tests) do
    local p = io.popen(t.cmd .. " 2>&1")
    local out = p:read("*a")
    p:close()

    if out:find(t.expect, 1, true) then
        print(string.format("  \27[32m✔ PASS [%d/%d]\27[0m: %s", i, #tests, t.name))
        passed = passed + 1
    else
        print(string.format("  \27[31m✘ FAIL [%d/%d]\27[0m: %s", i, #tests, t.name))
        print("    Expected substring: " .. t.expect)
        print("    Output received:    " .. out:sub(1, 200))
    end
end

-- =========================================================================
-- In-Depth Module, Cryptographic & FFI Tests
-- =========================================================================
print("\n--- In-Depth Cryptographic & State Verification Tests ---")
local enigma = require("ffi_enigma")
local EnigmaMachine   = enigma.EnigmaMachine
local EnigmaRotor     = enigma.EnigmaRotor
local EnigmaReflector = enigma.EnigmaReflector
local EnigmaPlugboard = enigma.EnigmaPlugboard
local ROTOR_DEFS      = enigma.ROTOR_DEFS
local REFLECTOR_DEFS  = enigma.REFLECTOR_DEFS
local utf8_w          = enigma.utf8_visible_width

local function assert_test(name, cond)
    total_tests = total_tests + 1
    if cond then
        passed = passed + 1
        print(string.format("  \27[32m✔ PASS\27[0m: %s", name))
    else
        print(string.format("  \27[31m✘ FAIL\27[0m: %s", name))
    end
end

-- 1. All Rotors (I to V) forward and reverse bijection checks
for _, name in ipairs({"I", "II", "III", "IV", "V"}) do
    local rotor = EnigmaRotor.new(name, "A", "A")
    local seen_fwd = {}
    local seen_rev = {}
    local bijective = true
    for x = 0, 25 do
        local f = rotor:forward(x)
        local r = rotor:reverse(f)
        if r ~= x or seen_fwd[f] then
            bijective = false
            break
        end
        seen_fwd[f] = true
    end
    assert_test(string.format("Rotor %s is an exact bijective permutation with reversible inverse", name), bijective)
end

-- 2. Reflectors UKW-B and UKW-C Involution Invariants (No self-loops, symmetric)
for _, name in ipairs({"UKW-B", "UKW-C"}) do
    local ref = EnigmaReflector.new(name)
    local involution = true
    local has_self_loop = false
    for x = 0, 25 do
        local y = ref:reflect(x)
        if x == y then has_self_loop = true end
        if ref:reflect(y) ~= x then involution = false end
    end
    assert_test(string.format("Reflector %s is a true involution (R(R(x)) == x)", name), involution)
    assert_test(string.format("Reflector %s contains zero self-loops (R(x) != x)", name), not has_self_loop)
end

-- 3. Plugboard Swapping Logic
local pb = EnigmaPlugboard.new("AV BS CG")
assert_test("Plugboard swap A <-> V", pb:swap(0) == 21 and pb:swap(21) == 0)
assert_test("Plugboard swap B <-> S", pb:swap(1) == 18 and pb:swap(18) == 1)
assert_test("Plugboard swap C <-> G", pb:swap(2) == 6 and pb:swap(6) == 2)
assert_test("Plugboard untouched letter D maps to itself", pb:swap(3) == 3)
assert_test("Plugboard pairs string formatted cleanly", pb:get_pairs_string() == "AV BS CG")

-- 4. Canonical Bletchley Park Test Vector (AAAAA -> BDZGO)
local m_canon = EnigmaMachine.new({ rotors = {"I", "II", "III"}, rings = "AAA", pos = "AAA", reflector = "UKW-B" })
local c_canon = m_canon:encode_text("AAAAA")
assert_test("Canonical Bletchley Park vector: AAAAA -> BDZGO", c_canon == "BDZGO")

local m_canon_dec = EnigmaMachine.new({ rotors = {"I", "II", "III"}, rings = "AAA", pos = "AAA", reflector = "UKW-B" })
local p_canon = m_canon_dec:encode_text(c_canon)
assert_test("Canonical vector decrypts reciprocally to AAAAA", p_canon == "AAAAA")

-- 5. Historical Double-Stepping Anomaly Sequence
local m_step = EnigmaMachine.new({ rotors = {"I", "II", "III"}, rings = "AAA", pos = "ADU" })
m_step:step_rotors()
assert_test("Step 1 (ADU -> ADV): Right rotor advances to notch",
    m_step.rotors[1]:get_char() == "A" and m_step.rotors[2]:get_char() == "D" and m_step.rotors[3]:get_char() == "V")

m_step:step_rotors()
assert_test("Step 2 (ADV -> AEW): Right advances past notch and turns middle",
    m_step.rotors[1]:get_char() == "A" and m_step.rotors[2]:get_char() == "E" and m_step.rotors[3]:get_char() == "W")

m_step:step_rotors()
assert_test("Step 3 (AEW -> BFX): Double-stepping triggers, middle turns again and advances left",
    m_step.rotors[1]:get_char() == "B" and m_step.rotors[2]:get_char() == "F" and m_step.rotors[3]:get_char() == "X")

m_step:step_rotors()
assert_test("Step 4 (BFX -> BFY): Normal single right step resumes",
    m_step.rotors[1]:get_char() == "B" and m_step.rotors[2]:get_char() == "F" and m_step.rotors[3]:get_char() == "Y")

-- 6. No-Self-Encryption Invariant ($E(M)_i \neq M_i$)
local m_rand = EnigmaMachine.new({
    rotors = {"I", "IV", "III"},
    rings = "XWB",
    pos = "QAZ",
    reflector = "UKW-B",
    plugs = "PO IU YR EW QL"
})
local long_text = "ENIGMAWASBROKENBYPOLISHSCHOOLANDBLETCHLEYPARKMATHEMATICIANS"
local long_cipher = m_rand:encode_text(long_text)
local self_match = false
for i = 1, #long_text do
    if long_text:sub(i, i) == long_cipher:sub(i, i) then
        self_match = true
        break
    end
end
assert_test("Enigma machine never encrypts a letter to itself (No-Self-Encryption invariant)", not self_match)

-- 7. Full Decryption Reciprocity on Long Message
local m_rand_dec = EnigmaMachine.new({
    rotors = {"I", "IV", "III"},
    rings = "XWB",
    pos = "QAZ",
    reflector = "UKW-B",
    plugs = "PO IU YR EW QL"
})
local long_plain = m_rand_dec:encode_text(long_cipher)
assert_test("Full message decrypts reciprocally to exact plaintext", long_plain == long_text)

-- 8. Undo / Backspace Engine Operation
local m_undo = EnigmaMachine.new({ rotors = {"I", "II", "III"}, pos = "AAA" })
m_undo:encode_char("H")
m_undo:encode_char("E")
m_undo:encode_char("L")
assert_test("Buffer holds HEL after typing 3 letters", m_undo.plaintext_buffer == "HEL")
assert_test("Undo reverts last letter", m_undo:undo() and m_undo.plaintext_buffer == "HE")
assert_test("Second undo reverts middle letter", m_undo:undo() and m_undo.plaintext_buffer == "H")
assert_test("Rotor positions restored after undo", m_undo.rotors[3]:get_char() == "B")

-- 9. TUI Layout Uniformity (All non-empty lines strictly 67 columns)
local function verify_frame_layout(machine)
    local frame = machine:render_frame()
    for line in frame:gmatch("([^\r\n]+)") do
        local w = utf8_w(line)
        if w > 0 and w ~= 67 then
            return false, string.format("Mismatch width %d on line: %s", w, line)
        end
    end
    return true
end

local m_tui_uni = EnigmaMachine.new()
local m_tui_asc = EnigmaMachine.new({ ascii_mode = true })
local m_tui_lit = EnigmaMachine.new()
m_tui_lit:encode_char("A") -- Lights a lamp

assert_test("TUI frame layout width is strictly 67 columns (Unicode default)", verify_frame_layout(m_tui_uni))
assert_test("TUI frame layout width is strictly 67 columns (ASCII mode)", verify_frame_layout(m_tui_asc))
assert_test("TUI frame layout width is strictly 67 columns with active illuminated lamp", verify_frame_layout(m_tui_lit))

-- 10. Non-interactive pipeline keystroke simulation
local pipe = io.popen("printf 'HELL\x7fOQ' | luajit enigma.lua --interactive 2>&1")
local pipe_out = pipe:read("*a")
pipe:close()
assert_test("Interactive pipeline keystroke loop executes and exits cleanly",
    pipe_out:find("Enigma Session Complete", 1, true) ~= nil and pipe_out:find("Plaintext : HELO", 1, true) ~= nil)

print(string.format("\nTest Summary: %d / %d tests passed.", passed, total_tests))
if passed == total_tests then
    print("\27[1;32mALL ENIGMA TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
else
    print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
    os.exit(1)
end
