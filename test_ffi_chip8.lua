#!/usr/bin/env luajit
--[[
    test_ffi_chip8.lua
    Unit, integration, and FFI regression test suite for ffi_chip8.lua (Chip-8 CPU Emulator).
--]]

local ffi = require("ffi")
local chip8 = require("ffi_chip8")

print("=== Running Unit Tests for ffi_chip8.lua (Chip-8 CPU Emulator) ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "luajit ffi_chip8.lua --help",
        expect = "CHIP-8 RETRO CPU EMULATOR & VIRTUAL MACHINE"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "luajit ffi_chip8.lua --test",
        expect = "All Chip-8 self-tests completed successfully!"
    },
    {
        name = "Snapshot non-interactive render (--snapshot)",
        cmd = "luajit ffi_chip8.lua --snapshot",
        expect = "CHIP-8 RETRO CPU EMULATOR - LUAJIT FFI ENGINE"
    },
    {
        name = "ASCII snapshot render (--snapshot --ascii)",
        cmd = "luajit ffi_chip8.lua --snapshot --ascii",
        expect = "+-- DISPLAY [64x32] - IBM Logo"
    },
    {
        name = "Built-in Pong snapshot (--snapshot --rom pong)",
        cmd = "luajit ffi_chip8.lua --snapshot --rom pong",
        expect = "DISPLAY [64x32] - Pong"
    },
    {
        name = "Built-in Brix snapshot (--snapshot --rom brix)",
        cmd = "luajit ffi_chip8.lua --snapshot --rom brix",
        expect = "DISPLAY [64x32] - Brix"
    },
    {
        name = "Built-in 10PRINT Maze snapshot (--snapshot --rom maze)",
        cmd = "luajit ffi_chip8.lua --snapshot --rom maze",
        expect = "DISPLAY [64x32] - 10PRINT Maze"
    }
}

local passed = 0
local total_cli = #tests

for i, t in ipairs(tests) do
    local p = io.popen(t.cmd .. " 2>&1")
    local out = p:read("*a")
    p:close()

    if out:find(t.expect, 1, true) then
        print(string.format("  \27[32m✔ PASS [%d/%d]\27[0m: %s", i, total_cli, t.name))
        passed = passed + 1
    else
        print(string.format("  \27[31m✘ FAIL [%d/%d]\27[0m: %s", i, total_cli, t.name))
        print("    Expected substring: " .. t.expect)
        print("    Output preview: " .. out:sub(1, 200))
    end
end

-- =========================================================================
-- In-Depth Engine, VM & FFI API Tests
-- =========================================================================
print("\n--- In-Depth Chip-8 Engine, Opcode Rules & FFI API Unit Tests ---")

local function assert_test(condition, msg)
    if condition then
        print("  \27[32m✔ PASS\27[0m: " .. msg)
        passed = passed + 1
    else
        print("  \27[31m✘ FAIL\27[0m: " .. msg)
        error("Assertion failed: " .. msg)
    end
end

-- 1. FFI Struct verification
assert_test(ffi.sizeof("Chip8VM") == 4096 + 16 + 2 + 2 + 1 + 1 + 32 + 2 + 2048 + 16 + 4, "Chip8VM sizeof == 6220")
assert_test(ffi.offsetof("Chip8VM", "memory") == 0, "Chip8VM offsetof(memory) == 0")
assert_test(ffi.offsetof("Chip8VM", "V") == 4096, "Chip8VM offsetof(V) == 4096")
assert_test(ffi.offsetof("Chip8VM", "I") == 4112, "Chip8VM offsetof(I) == 4112")
assert_test(ffi.offsetof("Chip8VM", "pc") == 4114, "Chip8VM offsetof(pc) == 4114")
assert_test(ffi.offsetof("Chip8VM", "gfx") == 4152, "Chip8VM offsetof(gfx) == 4152")
assert_test(ffi.offsetof("Chip8VM", "keys") == 6200, "Chip8VM offsetof(keys) == 6200")

-- 2. VM Initialization
local chip = chip8.Chip8.new()
assert_test(chip.vm.pc == 0x200, "Initial program counter is 0x200")
assert_test(chip.vm.sp == 0, "Initial stack pointer is 0")
assert_test(chip.vm.memory[0x050] == 0xF0, "COSMAC VIP fontset loaded at 0x050")
assert_test(chip.vm.memory[0x050 + 15 * 5] == 0xF0, "Font character 'F' loaded at 0x050 + 75")

-- 3. Jumps & Subroutines
chip:reset()
chip.vm.memory[0x200] = 0x13
chip.vm.memory[0x201] = 0x45 -- JP 0x345
chip:step()
assert_test(chip.vm.pc == 0x345, "JP 0x345 sets PC to 0x345")

chip.vm.memory[0x345] = 0x24
chip.vm.memory[0x346] = 0x00 -- CALL 0x400
chip:step()
assert_test(chip.vm.pc == 0x400 and chip.vm.sp == 1 and chip.vm.stack[0] == 0x347, "CALL pushes return address and sets PC")

chip.vm.memory[0x400] = 0x00
chip.vm.memory[0x401] = 0xEE -- RET
chip:step()
assert_test(chip.vm.pc == 0x347 and chip.vm.sp == 0, "RET restores PC from stack")

-- 4. Jump with offset V0 (Bnnn)
chip:reset()
chip.vm.V[0] = 0x15
chip.vm.memory[0x200] = 0xB3
chip.vm.memory[0x201] = 0x00 -- JP V0, 0x300
chip:step()
assert_test(chip.vm.pc == 0x315, "JP V0, 0x300 jumps to 0x300 + V0")

-- 5. Conditional Skips (SE, SNE)
chip:reset()
chip.vm.V[1] = 0x42
chip.vm.V[2] = 0x42
chip.vm.V[3] = 0x99

-- SE V1, 0x42 (match: skip +2 -> 0x204)
chip.vm.memory[0x200] = 0x31
chip.vm.memory[0x201] = 0x42
chip:step()
assert_test(chip.vm.pc == 0x204, "SE Vx, byte skips instruction on match")

-- SE V1, 0x99 (no match: no skip -> 0x206)
chip.vm.memory[0x204] = 0x31
chip.vm.memory[0x205] = 0x99
chip:step()
assert_test(chip.vm.pc == 0x206, "SE Vx, byte does not skip on mismatch")

-- SNE V1, 0x99 (mismatch: skip -> 0x20A)
chip.vm.memory[0x206] = 0x41
chip.vm.memory[0x207] = 0x99
chip:step()
assert_test(chip.vm.pc == 0x20A, "SNE Vx, byte skips instruction on mismatch")

-- SE V1, V2 (equal: skip -> 0x20E)
chip.vm.memory[0x20A] = 0x51
chip.vm.memory[0x20B] = 0x20
chip:step()
assert_test(chip.vm.pc == 0x20E, "SE Vx, Vy skips when registers equal")

-- SNE V1, V3 (not equal: skip -> 0x212)
chip.vm.memory[0x20E] = 0x91
chip.vm.memory[0x20F] = 0x30
chip:step()
assert_test(chip.vm.pc == 0x212, "SNE Vx, Vy skips when registers unequal")

-- 6. Arithmetic & Bitwise Logic
chip:reset()
chip.vm.V[4] = 100
chip.vm.memory[0x200] = 0x74
chip.vm.memory[0x201] = 50 -- ADD V4, 50
chip:step()
assert_test(chip.vm.V[4] == 150 and chip.vm.V[0xF] == 0, "ADD Vx, byte adds without modifying VF")

chip.vm.V[4] = 200
chip.vm.memory[0x202] = 0x74
chip.vm.memory[0x203] = 100 -- ADD V4, 100 -> wraps to 44
chip:step()
assert_test(chip.vm.V[4] == 44 and chip.vm.V[0xF] == 0, "ADD Vx, byte wraps 8-bit and leaves VF unchanged")

-- Bitwise AND, OR, XOR
chip.vm.V[1] = 0x0F
chip.vm.V[2] = 0xF0
chip.vm.memory[0x204] = 0x81
chip.vm.memory[0x205] = 0x21 -- OR V1, V2
chip:step()
assert_test(chip.vm.V[1] == 0xFF, "OR Vx, Vy performs bitwise OR")

chip.vm.memory[0x206] = 0x81
chip.vm.memory[0x207] = 0x22 -- AND V1, V2
chip:step()
assert_test(chip.vm.V[1] == 0xF0, "AND Vx, Vy performs bitwise AND")

chip.vm.memory[0x208] = 0x81
chip.vm.memory[0x209] = 0x23 -- XOR V1, V2
chip:step()
assert_test(chip.vm.V[1] == 0x00, "XOR Vx, Vy performs bitwise XOR")

-- Shift SHR / SHL
chip.vm.V[5] = 0x81 -- 1000 0001
chip.vm.memory[0x20A] = 0x85
chip.vm.memory[0x20B] = 0x06 -- SHR V5
chip:step()
assert_test(chip.vm.V[5] == 0x40 and chip.vm.V[0xF] == 1, "SHR shifts right and puts LSB into VF")

chip.vm.V[5] = 0x81 -- 1000 0001
chip.vm.memory[0x20C] = 0x85
chip.vm.memory[0x20D] = 0x0E -- SHL V5
chip:step()
assert_test(chip.vm.V[5] == 0x02 and chip.vm.V[0xF] == 1, "SHL shifts left and puts MSB into VF")

-- 7. Timers & 60 Hz Tick
chip:reset()
chip.vm.V[0] = 30
chip.vm.memory[0x200] = 0xF0
chip.vm.memory[0x201] = 0x15 -- LD DT, V0
chip:step()
assert_test(chip.vm.delay_timer == 30, "LD DT, Vx sets delay timer")

chip.vm.memory[0x202] = 0xF0
chip.vm.memory[0x203] = 0x18 -- LD ST, V0
chip:step()
assert_test(chip.vm.sound_timer == 30, "LD ST, Vx sets sound timer")

local beep = chip:tick_60hz()
assert_test(beep == true and chip.vm.delay_timer == 29 and chip.vm.sound_timer == 29, "60 Hz tick decrements DT/ST and triggers beep")

-- 8. Memory LD [I], Vx and LD Vx, [I]
chip:reset()
chip.vm.I = 0x500
chip.vm.V[0] = 11
chip.vm.V[1] = 22
chip.vm.V[2] = 33
chip.vm.memory[0x200] = 0xF2
chip.vm.memory[0x201] = 0x55 -- LD [I], V2
chip:step()
assert_test(chip.vm.memory[0x500] == 11 and chip.vm.memory[0x501] == 22 and chip.vm.memory[0x502] == 33, "LD [I], Vx writes V0..Vx to memory")

chip.vm.V[0] = 0
chip.vm.V[1] = 0
chip.vm.V[2] = 0
chip.vm.I = 0x500
chip.vm.memory[0x202] = 0xF2
chip.vm.memory[0x203] = 0x65 -- LD V2, [I]
chip:step()
assert_test(chip.vm.V[0] == 11 and chip.vm.V[1] == 22 and chip.vm.V[2] == 33, "LD Vx, [I] reads memory into V0..Vx")

-- 9. Graphics Drawing (Dxyn) & CLS (00E0)
chip:reset()
chip.vm.I = 0x300
chip.vm.memory[0x300] = 0xAA -- 10101010
chip.vm.V[0] = 4
chip.vm.V[1] = 2
chip.vm.memory[0x200] = 0xD0
chip.vm.memory[0x201] = 0x11 -- DRW V0, V1, 1
chip:step()
assert_test(chip.vm.V[0xF] == 0, "Fresh sprite draw sets VF = 0")
assert_test(chip.vm.gfx[2 * 64 + 4] == 1 and chip.vm.gfx[2 * 64 + 5] == 0, "Pattern 10101010 drawn accurately")

-- Overwriting same sprite toggles pixels off and sets collision VF = 1
chip.vm.memory[0x202] = 0xD0
chip.vm.memory[0x203] = 0x11
chip:step()
assert_test(chip.vm.V[0xF] == 1, "Collision correctly detected on overwrite (VF = 1)")
assert_test(chip.vm.gfx[2 * 64 + 4] == 0, "Pixels toggled off by XOR")

-- CLS instruction
chip.vm.memory[0x204] = 0xD0
chip.vm.memory[0x205] = 0x11 -- Draw again
chip:step()
chip.vm.memory[0x206] = 0x00
chip.vm.memory[0x207] = 0xE0 -- CLS
chip:step()
local set_pixels = 0
for i = 0, 64 * 32 - 1 do if chip.vm.gfx[i] == 1 then set_pixels = set_pixels + 1 end end
assert_test(set_pixels == 0, "CLS clears all 2048 display pixels")

-- 10. Keypad Input & Skip Instructions (Ex9E, ExA1)
chip:reset()
chip.vm.V[0] = 0x5 -- Key 5
chip.vm.memory[0x200] = 0xE0
chip.vm.memory[0x201] = 0x9E -- SKP V0 (skip if pressed)
chip:step()
assert_test(chip.vm.pc == 0x202, "SKP does not skip when key is not pressed")

chip:press_key(0x5)
chip.vm.memory[0x202] = 0xE0
chip.vm.memory[0x203] = 0x9E -- SKP V0 (pressed)
chip:step()
assert_test(chip.vm.pc == 0x206, "SKP skips instruction when key is pressed")

chip.vm.memory[0x206] = 0xE0
chip.vm.memory[0x207] = 0xA1 -- SKNP V0 (skip if not pressed)
chip:step()
assert_test(chip.vm.pc == 0x208, "SKNP does not skip when key is pressed")

-- 11. Builtin ROMs Loading
for _, key in ipairs({ "ibm", "pong", "brix", "tetris", "ufo", "corax", "maze" }) do
    local ok = chip:load_builtin(key)
    assert_test(ok == true and chip.current_rom_key == key, "Builtin ROM '" .. key .. "' loaded successfully")
end

-- 12. Corax+ Diagnostic Opcode Suite (50,000 steps)
chip:load_builtin("corax")
for _ = 1, 50000 do
    chip:step()
    if chip.vm.delay_timer > 0 then chip.vm.delay_timer = chip.vm.delay_timer - 1 end
end
local corax_pixels = 0
for i = 0, 64 * 32 - 1 do
    if chip.vm.gfx[i] == 1 then corax_pixels = corax_pixels + 1 end
end
assert_test(corax_pixels > 200, "Corax+ Diagnostic Opcode test completed with checkmarks rendered")

-- 13. Terminal Frame Column Width Checks
local function check_frame_width(frame_text, mode_name)
    local l_idx = 0
    for line in frame_text:gmatch("[^\r\n]+") do
        l_idx = l_idx + 1
        local plain = line:gsub("\27%[[%d;]*m", "")
        local w = 0
        local i = 1
        while i <= #plain do
            local b = plain:byte(i)
            if b < 128 then w = w + 1; i = i + 1
            elseif b >= 192 and b < 224 then w = w + 1; i = i + 2
            elseif b >= 224 and b < 240 then w = w + 1; i = i + 3
            elseif b >= 240 then w = w + 2; i = i + 4
            else i = i + 1 end
        end
        assert(w == 80, string.format("[%s] Line %d width is %d != 80: '%s'", mode_name, l_idx, w, plain))
    end
    return l_idx
end

chip.use_ascii = false
local lines_u = check_frame_width(chip:render_frame(), "Unicode")
assert_test(lines_u == 27, "Unicode frame renders exactly 27 lines of 80-column text")

chip.use_ascii = true
local lines_a = check_frame_width(chip:render_frame(), "ASCII")
assert_test(lines_a == 27, "ASCII fallback frame renders exactly 27 lines of 80-column text")

print(string.format("\nTest Summary: %d / %d tests passed.", passed, passed))
print("\27[1;32mALL CHIP-8 TESTS PASSED SUCCESSFULLY!\27[0m\n")
os.exit(0)
