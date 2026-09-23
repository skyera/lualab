local ffi = require("ffi")
local midi_synth = require("ffi_midi_keyboard")

local function assert_equal(actual, expected, message)
    assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assert_near(actual, expected, tolerance, message)
    local diff = math.abs(actual - expected)
    assert(diff <= tolerance, string.format("%s: expected ~%s, got %s (diff %s > %s)", message, expected, actual, diff, tolerance))
end

-- 1. Test MIDI to Frequency calculation
-- A4 is MIDI note 69 = 440 Hz
assert_near(midi_synth.midi_to_freq(69), 440.0, 0.01, "A4 frequency")
-- C4 (Middle C) is MIDI note 60 = 261.63 Hz
assert_near(midi_synth.midi_to_freq(60), 261.63, 0.05, "C4 Middle C frequency")
-- A5 is MIDI note 81 = 880 Hz
assert_near(midi_synth.midi_to_freq(81), 880.0, 0.01, "A5 frequency")
-- A3 is MIDI note 57 = 220 Hz
assert_near(midi_synth.midi_to_freq(57), 220.0, 0.01, "A3 frequency")

-- 2. Test MIDI Note Name mapping
local name, oct = midi_synth.midi_note_name(60)
assert_equal(name, "C", "C4 note name")
assert_equal(oct, 4, "C4 octave")

local name_a, oct_a = midi_synth.midi_note_name(69)
assert_equal(name_a, "A", "A4 note name")
assert_equal(oct_a, 4, "A4 octave")

local name_fs, oct_fs = midi_synth.midi_note_name(66)
assert_equal(name_fs, "F#", "F#4 note name")
assert_equal(oct_fs, 4, "F#4 octave")

-- 3. Test Synthesizer Audio Generation
local synth = midi_synth.Synth.new()
assert_equal(synth.waveform, "sine", "default waveform")

-- Test waveform changes
synth:set_waveform("saw")
assert_equal(synth.waveform, "saw", "set saw waveform")
synth:set_waveform("square")
assert_equal(synth.waveform, "square", "set square waveform")
synth:set_waveform("triangle")
assert_equal(synth.waveform, "triangle", "set triangle waveform")
synth:set_waveform("noise")
assert_equal(synth.waveform, "noise", "set noise waveform")
synth:set_waveform("invalid")
assert_equal(synth.waveform, "noise", "ignore invalid waveform")

-- Test note playback and buffer sample bounds
synth:set_waveform("sine")
local buffer = ffi.new("int16_t[?]", 1024)

-- Idle synth produces near-zero or zero samples
synth:generate_samples(buffer, 1024)
for i = 0, 1023 do
    assert_equal(buffer[i], 0, "idle synth should produce zero")
end

-- Trigger C4 note
synth:note_on(60, 1.0)
synth:generate_samples(buffer, 1024)

local non_zero_found = false
local within_bounds = true
for i = 0, 1023 do
    local val = buffer[i]
    if val ~= 0 then non_zero_found = true end
    if val < -32768 or val > 32767 then within_bounds = false end
end
assert(non_zero_found, "active note should produce audio signal")
assert(within_bounds, "audio samples must stay within signed 16-bit range [-32768, 32767]")

-- Test Polyphony: trigger multiple notes simultaneously
synth:note_on(64, 1.0) -- E4
synth:note_on(67, 1.0) -- G4
synth:generate_samples(buffer, 1024)
for i = 0, 1023 do
    local val = buffer[i]
    assert(val >= -32768 and val <= 32767, "polyphonic chord samples must not overflow 16-bit")
end

-- Test Note Off & All Notes Off
synth:all_notes_off()
-- After all notes off, voices should be in release state or off
for i = 1, synth.max_voices do
    assert(synth.voices[i].adsr_state == 5 or synth.voices[i].adsr_state == 4, "voices should be off/release after panic")
end

print("ffi_midi_keyboard: all tests passed")
