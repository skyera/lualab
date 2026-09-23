--[[
    ffi_midi_keyboard.lua — Interactive Real-time Synthesizer, Piano Keyboard & Oscilloscope
    Pure LuaJIT FFI audio synthesis engine & TUI virtual piano.

    Usage:
      luajit ffi_midi_keyboard.lua              -- start interactive synthesizer
      luajit ffi_midi_keyboard.lua --demo       -- play procedural arpeggio song
      luajit ffi_midi_keyboard.lua --wave saw   -- start with sawtooth waveform
      luajit ffi_midi_keyboard.lua --octave 4   -- start at octave 4

    Keys:
      Keyboard Piano:
        Lower octave:  Z(C) S(C#) X(D) D(D#) C(E) V(F) G(F#) B(G) H(G#) N(A) J(A#) M(B) ,(C)
        Upper octave:  Q(C) 2(C#) W(D) 3(D#) E(E) R(F) 5(F#) T(G) 6(G#) Y(A) 7(A#) U(B) I(C)
      Controls:
        1 - 5          Waveform: 1:Sine 2:Saw 3:Square 4:Triangle 5:Noise
        [ / ]          Shift octave down / up (1 - 7)
        + / = / - / _  Volume up / down
        e / E          Toggle Echo / Delay effect
        Space          All notes off (Panic / Mute)
        p              Play demo arpeggio
        ? / F1         Toggle help overlay
        q / Esc        Quit
]]

local ffi = require("ffi")
local bit = require("bit")

-- ============================================================
-- 1. FFI C Declarations (POSIX terminal, time, & audio)
-- ============================================================
local IS_WIN = (ffi.os == "Windows")

ffi.cdef[[
    typedef unsigned char  cc_t;
    typedef unsigned int   speed_t;
    typedef unsigned int   tcflag_t;
    struct termios {
        tcflag_t c_iflag; tcflag_t c_oflag; tcflag_t c_cflag; tcflag_t c_lflag;
        cc_t c_line; cc_t c_cc[32]; speed_t c_ispeed; speed_t c_ospeed;
    };
    int tcgetattr(int fd, struct termios *termios_p);
    int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
    struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
    int ioctl(int fd, unsigned long request, void *argp);
    int isatty(int fd);
    struct pollfd { int fd; short events; short revents; };
    int poll(struct pollfd *fds, unsigned long nfds, int timeout);
    long read(int fd, void *buf, size_t count);

    // High resolution time
    typedef long time_t;
    struct timespec { time_t tv_sec; long tv_nsec; };
    int clock_gettime(int clk_id, struct timespec *tp);
    int usleep(unsigned int usec);
]]

local function get_time_sec()
    local ts = ffi.new("struct timespec")
    ffi.C.clock_gettime(0, ts) -- CLOCK_REALTIME = 0
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
end

-- ============================================================
-- 2. Audio Backend (ALSA / Pulse / pipe fallback)
-- ============================================================
local SAMPLE_RATE = 44100
local CHANNELS    = 1
local BUFFER_SIZE = 1024 -- ~23ms per chunk

local audio_backend = { mode = "none", handle = nil }

local function init_audio()
    -- Try ALSA libasound.so first
    local ok_asound, asound = pcall(ffi.load, "asound")
    if ok_asound then
        local ok_cdef = pcall(ffi.cdef, [[
            typedef struct _snd_pcm snd_pcm_t;
            typedef struct _snd_pcm_hw_params snd_pcm_hw_params_t;
            int snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode);
            int snd_pcm_hw_params_malloc(snd_pcm_hw_params_t **ptr);
            void snd_pcm_hw_params_free(snd_pcm_hw_params_t *obj);
            int snd_pcm_hw_params_any(snd_pcm_t *pcm, snd_pcm_hw_params_t *params);
            int snd_pcm_hw_params_set_access(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, int _access);
            int snd_pcm_hw_params_set_format(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, int val);
            int snd_pcm_hw_params_set_channels(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int val);
            int snd_pcm_hw_params_set_rate_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int *dir);
            int snd_pcm_hw_params_set_period_size_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned long *val, int *dir);
            int snd_pcm_hw_params(snd_pcm_t *pcm, snd_pcm_hw_params_t *params);
            int snd_pcm_prepare(snd_pcm_t *pcm);
            long snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, unsigned long size);
            int snd_pcm_close(snd_pcm_t *pcm);
            int snd_pcm_recover(snd_pcm_t *pcm, int err, int silent);
        ]])
        if ok_cdef then
            local pcm = ffi.new("snd_pcm_t*[1]")
            -- SND_PCM_STREAM_PLAYBACK = 0, SND_PCM_NONBLOCK = 1
            if asound.snd_pcm_open(pcm, "default", 0, 1) == 0 then
                local hw = ffi.new("snd_pcm_hw_params_t*[1]")
                asound.snd_pcm_hw_params_malloc(hw)
                asound.snd_pcm_hw_params_any(pcm[0], hw[0])
                -- SND_PCM_ACCESS_RW_INTERLEAVED = 3, SND_PCM_FORMAT_S16_LE = 2
                asound.snd_pcm_hw_params_set_access(pcm[0], hw[0], 3)
                asound.snd_pcm_hw_params_set_format(pcm[0], hw[0], 2)
                asound.snd_pcm_hw_params_set_channels(pcm[0], hw[0], CHANNELS)
                local rate = ffi.new("unsigned int[1]", SAMPLE_RATE)
                asound.snd_pcm_hw_params_set_rate_near(pcm[0], hw[0], rate, nil)
                local period = ffi.new("unsigned long[1]", BUFFER_SIZE)
                asound.snd_pcm_hw_params_set_period_size_near(pcm[0], hw[0], period, nil)
                asound.snd_pcm_hw_params(pcm[0], hw[0])
                asound.snd_pcm_hw_params_free(hw[0])
                asound.snd_pcm_prepare(pcm[0])

                audio_backend.mode = "alsa"
                audio_backend.handle = pcm[0]
                audio_backend.lib = asound
                return audio_backend
            end
        end
    end

    -- Pipe fallback to aplay or paplay
    local pipe = io.popen("aplay -q -f S16_LE -c 1 -r 44100 -t raw 2>/dev/null", "w")
    if pipe then
        audio_backend.mode = "pipe"
        audio_backend.handle = pipe
        return audio_backend
    end

    pipe = io.popen("paplay --raw --channels=1 --rate=44100 --format=s16le 2>/dev/null", "w")
    if pipe then
        audio_backend.mode = "pipe"
        audio_backend.handle = pipe
        return audio_backend
    end

    return audio_backend
end

local function write_audio_samples(samples, count)
    if audio_backend.mode == "alsa" then
        local frames_written = audio_backend.lib.snd_pcm_writei(audio_backend.handle, samples, count)
        if frames_written < 0 then
            audio_backend.lib.snd_pcm_recover(audio_backend.handle, tonumber(frames_written), 1)
        end
    elseif audio_backend.mode == "pipe" and audio_backend.handle then
        local bytes = ffi.string(samples, count * 2)
        audio_backend.handle:write(bytes)
        audio_backend.handle:flush()
    end
end

local function close_audio()
    if audio_backend.mode == "alsa" and audio_backend.handle then
        audio_backend.lib.snd_pcm_close(audio_backend.handle)
        audio_backend.handle = nil
    elseif audio_backend.mode == "pipe" and audio_backend.handle then
        audio_backend.handle:close()
        audio_backend.handle = nil
    end
end

-- ============================================================
-- 3. Sound Synthesis & DSP Engine
-- ============================================================
-- MIDI note to frequency in Hz: f = 440 * 2^((midi - 69) / 12)
local function midi_to_freq(midi_note)
    return 440.0 * (2.0 ^ ((midi_note - 69.0) / 12.0))
end

local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

local function midi_note_name(midi_note)
    local note_idx = (midi_note % 12) + 1
    local octave = math.floor(midi_note / 12) - 1
    return NOTE_NAMES[note_idx], octave
end

-- ADSR Envelope state machine
local ADSR_ATTACK, ADSR_DECAY, ADSR_SUSTAIN, ADSR_RELEASE, ADSR_OFF = 1, 2, 3, 4, 5

local Synth = {}
Synth.__index = Synth

function Synth.new()
    local self = setmetatable({}, Synth)
    self.waveform = "sine"     -- sine, saw, square, triangle, noise
    self.master_vol = 0.7
    self.echo_on = false
    self.echo_buffer = ffi.new("int16_t[?]", 22050) -- 500ms delay buffer
    self.echo_pos = 0

    -- Polyphony: 8 voices
    self.max_voices = 8
    self.voices = {}
    for i = 1, self.max_voices do
        self.voices[i] = {
            active = false,
            midi = 0,
            freq = 0,
            phase = 0.0,
            phase_inc = 0.0,
            adsr_state = ADSR_OFF,
            adsr_level = 0.0,
            velocity = 1.0,
            age = 0,
        }
    end

    -- ADSR Envelope parameters (in seconds)
    self.attack_time  = 0.015
    self.decay_time   = 0.080
    self.sustain_lvl  = 0.650
    self.release_time = 0.200

    -- Oscilloscope probe buffer
    self.scope_size = 64
    self.scope_buf  = ffi.new("int16_t[?]", self.scope_size)

    return self
end

function Synth:note_on(midi_note, velocity)
    velocity = velocity or 1.0
    -- If already playing, re-trigger
    for i = 1, self.max_voices do
        local v = self.voices[i]
        if v.active and v.midi == midi_note then
            v.adsr_state = ADSR_ATTACK
            v.velocity = velocity
            v.age = 0
            return
        end
    end

    -- Find free voice or steal oldest
    local best_idx = 1
    local max_age = -1
    for i = 1, self.max_voices do
        local v = self.voices[i]
        if not v.active or v.adsr_state == ADSR_OFF then
            best_idx = i
            break
        elseif v.adsr_state == ADSR_RELEASE and v.age > max_age then
            best_idx = i
            max_age = v.age
        elseif v.age > max_age then
            best_idx = i
            max_age = v.age
        end
    end

    local v = self.voices[best_idx]
    v.active = true
    v.midi = midi_note
    v.freq = midi_to_freq(midi_note)
    v.phase = 0.0
    v.phase_inc = (v.freq * 2.0 * math.pi) / SAMPLE_RATE
    v.adsr_state = ADSR_ATTACK
    v.adsr_level = 0.0
    v.velocity = velocity
    v.age = 0
end

function Synth:note_off(midi_note)
    for i = 1, self.max_voices do
        local v = self.voices[i]
        if v.active and v.midi == midi_note and v.adsr_state ~= ADSR_OFF then
            v.adsr_state = ADSR_RELEASE
        end
    end
end

function Synth:all_notes_off()
    for i = 1, self.max_voices do
        self.voices[i].adsr_state = ADSR_OFF
        self.voices[i].active = false
        self.voices[i].adsr_level = 0.0
    end
end

function Synth:set_waveform(w)
    if w == "sine" or w == "saw" or w == "square" or w == "triangle" or w == "noise" then
        self.waveform = w
    end
end

function Synth:generate_samples(output_buffer, count)
    local dt = 1.0 / SAMPLE_RATE
    local att_step = 1.0 / math.max(0.001, self.attack_time * SAMPLE_RATE)
    local dec_step = (1.0 - self.sustain_lvl) / math.max(0.001, self.decay_time * SAMPLE_RATE)
    local rel_step = self.sustain_lvl / math.max(0.001, self.release_time * SAMPLE_RATE)
    local two_pi = 2.0 * math.pi

    local wave = self.waveform
    local master = self.master_vol
    local active_count = 0

    for i = 0, count - 1 do
        local sum = 0.0

        for vi = 1, self.max_voices do
            local v = self.voices[vi]
            if v.active then
                -- Process ADSR
                local st = v.adsr_state
                if st == ADSR_ATTACK then
                    v.adsr_level = v.adsr_level + att_step
                    if v.adsr_level >= 1.0 then
                        v.adsr_level = 1.0
                        v.adsr_state = ADSR_DECAY
                    end
                elseif st == ADSR_DECAY then
                    v.adsr_level = v.adsr_level - dec_step
                    if v.adsr_level <= self.sustain_lvl then
                        v.adsr_level = self.sustain_lvl
                        v.adsr_state = ADSR_SUSTAIN
                    end
                elseif st == ADSR_SUSTAIN then
                    v.adsr_level = self.sustain_lvl
                elseif st == ADSR_RELEASE then
                    v.adsr_level = v.adsr_level - rel_step
                    if v.adsr_level <= 0.0 then
                        v.adsr_level = 0.0
                        v.adsr_state = ADSR_OFF
                        v.active = false
                    end
                end

                if v.active and v.adsr_level > 0.0 then
                    active_count = active_count + 1
                    local ph = v.phase
                    local s = 0.0

                    if wave == "sine" then
                        s = math.sin(ph)
                    elseif wave == "saw" then
                        s = (ph / math.pi) - 1.0
                    elseif wave == "square" then
                        s = ph < math.pi and 1.0 or -1.0
                    elseif wave == "triangle" then
                        s = 1.0 - math.abs((ph / math.pi) - 1.0) * 2.0
                    elseif wave == "noise" then
                        s = math.random() * 2.0 - 1.0
                    end

                    sum = sum + s * v.adsr_level * v.velocity
                    v.phase = (ph + v.phase_inc) % two_pi
                    v.age = v.age + 1
                end
            end
        end

        -- Scale and clamp to 16-bit signed PCM
        local sample_val = sum * master * 16384.0

        -- Apply Echo / Delay effect
        if self.echo_on then
            local delay_sample = self.echo_buffer[self.echo_pos]
            sample_val = sample_val + delay_sample * 0.4
            self.echo_buffer[self.echo_pos] = math.max(-32768, math.min(32767, math.floor(sample_val)))
            self.echo_pos = (self.echo_pos + 1) % 22050
        end

        local clamped = math.max(-32768, math.min(32767, math.floor(sample_val + 0.5)))
        output_buffer[i] = clamped

        -- Feed oscilloscope probe
        if i < self.scope_size then
            self.scope_buf[i] = clamped
        end
    end
end

-- ============================================================
-- 4. Terminal Raw Mode & Input Handling
-- ============================================================
local STDIN = 0
local orig_termios = ffi.new("struct termios")
local raw_termios  = ffi.new("struct termios")
local raw_on = false

local function enable_raw_mode()
    local ok, r = pcall(function() return ffi.C.isatty(STDIN) end)
    if not (ok and r == 1) then return false end
    ffi.C.tcgetattr(STDIN, orig_termios)
    ffi.C.tcgetattr(STDIN, raw_termios)
    raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(2, 8))) -- ICANON=2, ECHO=8
    ffi.C.tcsetattr(STDIN, 0, raw_termios) -- TCSANOW = 0
    raw_on = true
    io.write("\27[?1049h\27[?25l"); io.flush()
    return true
end

local function disable_raw_mode()
    if raw_on then
        io.write("\27[?1049l\27[?25h\27[0m"); io.flush()
        ffi.C.tcsetattr(STDIN, 0, orig_termios)
        raw_on = false
    end
end

local pfd  = ffi.new("struct pollfd", { fd = STDIN, events = 1, revents = 0 }) -- POLLIN = 1
local kbuf = ffi.new("char[16]")

local function poll_key()
    local ret = ffi.C.poll(pfd, 1, 0) -- 0ms non-blocking
    if ret > 0 and bit.band(pfd.revents, 1) ~= 0 then
        local n = ffi.C.read(STDIN, kbuf, 16)
        if n > 0 then
            local c0 = bit.band(kbuf[0], 0xFF)
            if c0 == 27 then
                if n >= 3 and kbuf[1] == 91 then
                    local c2 = kbuf[2]
                    if c2 == 65 then return "UP"    end
                    if c2 == 66 then return "DOWN"  end
                    if c2 == 67 then return "RIGHT" end
                    if c2 == 68 then return "LEFT"  end
                    if c2 == 53 then return "PAGE_UP" end
                    if c2 == 54 then return "PAGE_DOWN" end
                    if c2 == 49 and n >= 4 and kbuf[3] == 49 then return "F1" end
                end
                return "ESC"
            elseif c0 == 10 or c0 == 13 then return "ENTER"
            elseif c0 == 32               then return "SPACE"
            elseif c0 == 3                then return "CTRL_C"
            elseif c0 >= 32               then return string.char(c0)
            end
        end
    end
    return nil
end

local function get_terminal_size()
    local ws = ffi.new("struct winsize")
    local TIOCGWINSZ = (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413
    if pcall(function() return ffi.C.ioctl(1, TIOCGWINSZ, ws) end)
       and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    return 80, 24
end

-- ============================================================
-- 5. Piano Keyboard Mapping
-- ============================================================
-- Base Octave 4: C4 is MIDI note 60
local KEY_MAP = {
    -- Lower row (Base Octave)
    ['z'] = 0,  ['s'] = 1,  ['x'] = 2,  ['d'] = 3,  ['c'] = 4,
    ['v'] = 5,  ['g'] = 6,  ['b'] = 7,  ['h'] = 8,  ['n'] = 9,
    ['j'] = 10, ['m'] = 11, [','] = 12,

    -- Upper row (+1 Octave)
    ['q'] = 12, ['2'] = 13, ['w'] = 14, ['3'] = 15, ['e'] = 16,
    ['r'] = 17, ['5'] = 18, ['t'] = 19, ['6'] = 20, ['y'] = 21,
    ['7'] = 22, ['u'] = 23, ['i'] = 24,
}

-- Key positions for visual rendering (two octaves: 14 white keys)
-- C, D, E, F, G, A, B, C, D, E, F, G, A, B
local WHITE_KEYS = {
    { note="C", semi=0,  key_lo="Z", key_hi="Q" },
    { note="D", semi=2,  key_lo="X", key_hi="W" },
    { note="E", semi=4,  key_lo="C", key_hi="E" },
    { note="F", semi=5,  key_lo="V", key_hi="R" },
    { note="G", semi=7,  key_lo="B", key_hi="T" },
    { note="A", semi=9,  key_lo="N", key_hi="Y" },
    { note="B", semi=11, key_lo="M", key_hi="U" },
}

local BLACK_KEYS = {
    { note="C#", semi=1,  pos=1, key_lo="S", key_hi="2" },
    { note="D#", semi=3,  pos=2, key_lo="D", key_hi="3" },
    { note="F#", semi=6,  pos=4, key_lo="G", key_hi="5" },
    { note="G#", semi=8,  pos=5, key_lo="H", key_hi="6" },
    { note="A#", semi=10, pos=6, key_lo="J", key_hi="7" },
}

-- ============================================================
-- 6. TUI Renderer: Oscilloscope, Piano & Status Bar
-- ============================================================
local function render_oscilloscope(synth, width)
    width = math.max(20, math.min(width, 76))
    local height = 5
    local grid = {}
    for y = 1, height do
        grid[y] = {}
        for x = 1, width do grid[y][x] = " " end
    end

    local mid_y = 3
    for x = 1, width do
        local buf_idx = math.floor((x - 1) / width * synth.scope_size)
        local val = synth.scope_buf[buf_idx] or 0
        local norm = val / 32768.0
        local y = mid_y - math.floor(norm * 2.2 + 0.5)
        y = math.max(1, math.min(height, y))
        grid[y][x] = "█"
    end

    local lines = {}
    for y = 1, height do
        local row = table.concat(grid[y])
        lines[#lines+1] = "\27[90m│ \27[1;32m" .. row .. "\27[90m │\27[0m\27[K\n"
    end
    return table.concat(lines)
end

local function is_key_active(synth, target_midi)
    for i = 1, synth.max_voices do
        local v = synth.voices[i]
        if v.active and v.midi == target_midi and v.adsr_state ~= ADSR_OFF then
            return true
        end
    end
    return false
end

local function render_piano(synth, base_octave)
    -- Two octaves displayed side-by-side (2 x 7 white keys = 14 white keys total)
    local out = {}
    local base_midi = (base_octave + 1) * 12

    -- 14 white keys, width = 5 chars each -> 70 chars wide
    -- Top row of black keys
    local r1 = { "\27[90m ┌" }
    for oct = 0, 1 do
        for k = 1, 7 do
            r1[#r1+1] = (oct == 1 and k == 7) and "─────┐" or "─────┬"
        end
    end
    out[#out+1] = table.concat(r1) .. "\27[0m\27[K\n"

    -- Black key upper row
    local r2 = { " │" }
    for oct = 0, 1 do
        local o_midi = base_midi + oct * 12
        local b_active = {
            is_key_active(synth, o_midi + 1),
            is_key_active(synth, o_midi + 3),
            false,
            is_key_active(synth, o_midi + 6),
            is_key_active(synth, o_midi + 8),
            is_key_active(synth, o_midi + 10),
            false
        }
        local b_names = { "C#", "D#", "  ", "F#", "G#", "A#", "  " }
        local b_keys  = oct == 0 and { "S", "D", " ", "G", "H", "J", " " }
                                 or  { "2", "3", " ", "5", "6", "7", " " }

        for k = 1, 7 do
            if b_names[k] ~= "  " then
                local col = b_active[k] and "\27[1;30;43m" or "\27[1;37;40m"
                r2[#r2+1] = col .. " " .. b_names[k] .. " \27[0m│"
            else
                r2[#r2+1] = "     │"
            end
        end
    end
    out[#out+1] = table.concat(r2) .. "\27[K\n"

    -- Black key shortcut label row
    local r3 = { " │" }
    for oct = 0, 1 do
        local o_midi = base_midi + oct * 12
        local b_active = {
            is_key_active(synth, o_midi + 1),
            is_key_active(synth, o_midi + 3),
            false,
            is_key_active(synth, o_midi + 6),
            is_key_active(synth, o_midi + 8),
            is_key_active(synth, o_midi + 10),
            false
        }
        local b_keys = oct == 0 and { "S", "D", " ", "G", "H", "J", " " }
                                or  { "2", "3", " ", "5", "6", "7", " " }

        for k = 1, 7 do
            if b_keys[k] ~= " " then
                local col = b_active[k] and "\27[1;30;43m" or "\27[93;40m"
                r3[#r3+1] = col .. " [" .. b_keys[k] .. "]\27[0m│"
            else
                r3[#r3+1] = "     │"
            end
        end
    end
    out[#out+1] = table.concat(r3) .. "\27[K\n"

    -- White key middle row
    local r4 = { " │" }
    for oct = 0, 1 do
        local o_midi = base_midi + oct * 12
        for k = 1, 7 do
            local wk = WHITE_KEYS[k]
            local active = is_key_active(synth, o_midi + wk.semi)
            local col = active and "\27[1;30;46m" or "\27[1;37m"
            r4[#r4+1] = col .. "  " .. wk.note .. "  \27[0m│"
        end
    end
    out[#out+1] = table.concat(r4) .. "\27[K\n"

    -- White key keybinding row
    local r5 = { " │" }
    for oct = 0, 1 do
        local o_midi = base_midi + oct * 12
        for k = 1, 7 do
            local wk = WHITE_KEYS[k]
            local key_lbl = (oct == 0) and wk.key_lo or wk.key_hi
            local active = is_key_active(synth, o_midi + wk.semi)
            local col = active and "\27[1;30;46m" or "\27[96m"
            r5[#r5+1] = col .. " [" .. key_lbl .. "] \27[0m│"
        end
    end
    out[#out+1] = table.concat(r5) .. "\27[K\n"

    -- Bottom border
    local r6 = { "\27[90m └" }
    for oct = 0, 1 do
        for k = 1, 7 do
            r6[#r6+1] = (oct == 1 and k == 7) and "─────┘" or "─────┴"
        end
    end
    out[#out+1] = table.concat(r6) .. "\27[0m\27[K\n"

    return table.concat(out)
end

local function show_synth_help()
    local term_w, term_h = get_terminal_size()
    local box_w = math.min(70, math.max(40, term_w - 4))
    local pleft = string.rep(" ", math.max(0, math.floor((term_w - box_w) / 2)))

    local out = { "\27[H\27[2J" }
    out[#out+1] = pleft .. "\27[1;36m┏━ 🎹 FFI MIDI KEYBOARD & SYNTHESIZER HELP ━━━━━━━━━━━━━━━━━━━━━━┓\27[0m\n"
    out[#out+1] = pleft .. "┃                                                                ┃\n"
    out[#out+1] = pleft .. "┃  \27[1;33mKEYBOARD PIANO:\27[0m                                               ┃\n"
    out[#out+1] = pleft .. "┃    Lower Octave:  Z=C  S=C# X=D  D=D# C=E  V=F  G=F#           ┃\n"
    out[#out+1] = pleft .. "┃                   B=G  H=G# N=A  J=A# M=B  ,=C                 ┃\n"
    out[#out+1] = pleft .. "┃    Upper Octave:  Q=C  2=C# W=D  3=D# E=E  R=F  5=F#           ┃\n"
    out[#out+1] = pleft .. "┃                   T=G  6=G# Y=A  7=A# U=B  I=C                 ┃\n"
    out[#out+1] = pleft .. "┃                                                                ┃\n"
    out[#out+1] = pleft .. "┃  \27[1;33mSYNTHESIZER CONTROLS:\27[0m                                         ┃\n"
    out[#out+1] = pleft .. "┃    [1 - 5]        Waveform: Sine, Sawtooth, Square, Tri, Noise ┃\n"
    out[#out+1] = pleft .. "┃    [ / ]          Octave Shift Down / Up (1 - 7)               ┃\n"
    out[#out+1] = pleft .. "┃    + / = / - / _  Master Volume Up / Down                      ┃\n"
    out[#out+1] = pleft .. "┃    e              Toggle Echo / Delay FX                       ┃\n"
    out[#out+1] = pleft .. "┃    p              Play Procedural Demo Arpeggio                ┃\n"
    out[#out+1] = pleft .. "┃    Space          All Notes Off (Panic/Mute)                   ┃\n"
    out[#out+1] = pleft .. "┃    q / Esc        Quit application                             ┃\n"
    out[#out+1] = pleft .. "┃                                                                ┃\n"
    out[#out+1] = pleft .. "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ [Press any key to close] ┛\27[0m\n"

    io.write(table.concat(out))
    io.flush()

    while true do
        local k = poll_key()
        if k then break end
        ffi.C.usleep(20000)
    end
end

-- ============================================================
-- 7. Interactive Main Loop
-- ============================================================
local function run_tui(start_octave, start_wave, auto_demo)
    init_audio()
    if not enable_raw_mode() then
        io.stderr:write("Error: standard input is not a terminal TTY.\n")
        return false
    end

    local synth = Synth.new()
    if start_wave then synth:set_waveform(start_wave) end
    local base_octave = start_octave or 4
    local running = true

    -- Audio output frame buffer
    local pcm_buf = ffi.new("int16_t[?]", BUFFER_SIZE)

    -- Auto note decay timers for non-blocking single-key hits
    local key_release_at = {}

    -- Demo player state
    local demo_active = auto_demo or false
    local demo_step = 1
    local demo_notes = {
        60, 64, 67, 71, 72, 71, 67, 64, -- Cmaj7
        57, 60, 64, 69, 72, 69, 64, 60, -- Am7
        53, 57, 60, 65, 69, 65, 60, 57, -- Fmaj7
        55, 59, 62, 67, 71, 67, 62, 59, -- G7
    }
    local demo_next_time = 0

    local ok_loop, err_loop = pcall(function()
        while running do
            local now = get_time_sec()

            -- Handle procedural demo
            if demo_active and now >= demo_next_time then
                local note = demo_notes[demo_step]
                synth:note_on(note, 0.85)
                key_release_at[note] = now + 0.16
                demo_step = (demo_step % #demo_notes) + 1
                demo_next_time = now + 0.18
            end

            -- Check note releases
            for midi, rel_time in pairs(key_release_at) do
                if now >= rel_time then
                    synth:note_off(midi)
                    key_release_at[midi] = nil
                end
            end

            -- 1. Read input key
            local key = poll_key()
            if key then
                if key == "q" or key == "Q" or key == "ESC" or key == "CTRL_C" then
                    running = false
                elseif key == "?" or key == "F1" then
                    synth:all_notes_off()
                    show_synth_help()
                elseif key == "SPACE" then
                    synth:all_notes_off()
                    demo_active = false
                elseif key == "p" or key == "P" then
                    demo_active = not demo_active
                    demo_next_time = now
                    if not demo_active then synth:all_notes_off() end
                elseif key == "1" then synth:set_waveform("sine")
                elseif key == "2" then synth:set_waveform("saw")
                elseif key == "3" then synth:set_waveform("square")
                elseif key == "4" then synth:set_waveform("triangle")
                elseif key == "5" then synth:set_waveform("noise")
                elseif key == "[" then base_octave = math.max(1, base_octave - 1)
                elseif key == "]" then base_octave = math.min(7, base_octave + 1)
                elseif key == "+" or key == "=" then
                    synth.master_vol = math.min(1.0, synth.master_vol + 0.05)
                elseif key == "-" or key == "_" then
                    synth.master_vol = math.max(0.0, synth.master_vol - 0.05)
                elseif key == "e" or key == "E" then
                    synth.echo_on = not synth.echo_on
                else
                    local lk = key:lower()
                    local semi_offset = KEY_MAP[lk]
                    if semi_offset then
                        local midi = (base_octave + 1) * 12 + semi_offset
                        synth:note_on(midi, 0.9)
                        key_release_at[midi] = now + 0.35 -- sustain for 350ms
                    end
                end
            end

            -- 2. Generate and stream audio samples
            synth:generate_samples(pcm_buf, BUFFER_SIZE)
            write_audio_samples(pcm_buf, BUFFER_SIZE)

            -- 3. Render frame to terminal
            local term_w, term_h = get_terminal_size()
            local out = { "\27[H" }

            -- Header line 1
            local wave_names = { sine="1:Sine", saw="2:Saw", square="3:Square", triangle="4:Triangle", noise="5:Noise" }
            local wave_tags = {}
            for _, w in ipairs({ "sine", "saw", "square", "triangle", "noise" }) do
                if synth.waveform == w then
                    wave_tags[#wave_tags+1] = "\27[1;30;43m " .. wave_names[w] .. " \27[0m"
                else
                    wave_tags[#wave_tags+1] = "\27[90m" .. wave_names[w] .. "\27[0m"
                end
            end

            out[#out+1] = string.format(
                "\27[1;36m 🎹 ffi_midi_keyboard\27[0m  %s  \27[90mOctave: \27[1;37m%d\27[90m (C%d–C%d)  Vol: \27[1;32m%d%%\27[0m  %s\27[K\n",
                table.concat(wave_tags, " "), base_octave, base_octave, base_octave + 2,
                math.floor(synth.master_vol * 100),
                synth.echo_on and "\27[1;35m[ECHO ON]\27[0m" or "\27[90m[ECHO OFF]\27[0m"
            )

            -- Header line 2 (Quick hints)
            out[#out+1] = string.format(
                "\27[90m [Z..M, Q..I] Play · [1-5] Wave · [[/]] Octave · [e] Echo · [p] Demo (%s) · [?] Help · [q] Quit\27[0m\27[K\n",
                demo_active and "\27[1;32mPLAYING\27[90m" or "OFF"
            )
            out[#out+1] = "\27[K\n"

            -- Oscilloscope view
            out[#out+1] = "\27[1;33m LIVE OSCILLOSCOPE (44.1 kHz PCM):\27[0m\27[K\n"
            out[#out+1] = "\27[90m ┌" .. string.rep("─", math.min(76, term_w - 4)) .. "┐\27[0m\27[K\n"
            out[#out+1] = render_oscilloscope(synth, math.min(76, term_w - 4))
            out[#out+1] = "\27[90m └" .. string.rep("─", math.min(76, term_w - 4)) .. "┘\27[0m\27[K\n"
            out[#out+1] = "\27[K\n"

            -- Interactive Virtual Piano
            out[#out+1] = "\27[1;36m INTERACTIVE PIANO KEYBOARD:\27[0m\27[K\n"
            out[#out+1] = render_piano(synth, base_octave)

            -- Active notes summary footer
            local active_names = {}
            for vi = 1, synth.max_voices do
                local v = synth.voices[vi]
                if v.active and v.adsr_state ~= ADSR_OFF then
                    local n, oct = midi_note_name(v.midi)
                    active_names[#active_names+1] = string.format("\27[1;36m%s%d\27[90m(%.1fHz)", n, oct, v.freq)
                end
            end
            local active_str = #active_names > 0 and table.concat(active_names, " ") or "\27[90mnone (idle)"
            out[#out+1] = string.format("\27[90m Active Voices: %s\27[0m\27[K\n", active_str)

            out[#out+1] = "\27[J"
            io.write(table.concat(out))
            io.flush()
        end
    end)

    disable_raw_mode()
    close_audio()

    if not ok_loop then
        io.stderr:write("MIDI Keyboard error: " .. tostring(err_loop) .. "\n")
        return false
    end
    return true
end

-- ============================================================
-- 8. Module API (for tests and embeddings)
-- ============================================================
local module = {
    midi_to_freq = midi_to_freq,
    midi_note_name = midi_note_name,
    Synth = Synth,
}

if ... == "ffi_midi_keyboard" then return module end

-- ============================================================
-- 9. CLI Entry Point
-- ============================================================
local start_octave = 4
local start_wave   = "sine"
local auto_demo    = false

local i = 1
while i <= #arg do
    local a = arg[i]
    if (a == "--octave" or a == "-o") and arg[i+1] then
        start_octave = tonumber(arg[i+1]) or 4
        i = i + 2
    elseif (a == "--wave" or a == "-w") and arg[i+1] then
        start_wave = arg[i+1]
        i = i + 2
    elseif a == "--demo" or a == "-d" then
        auto_demo = true
        i = i + 1
    elseif a == "--help" or a == "-h" then
        print("Usage: luajit ffi_midi_keyboard.lua [options]")
        print("  --octave N, -o N    Initial base octave (1 - 7, default: 4)")
        print("  --wave W,   -w W    Initial waveform (sine, saw, square, triangle, noise)")
        print("  --demo,     -d      Launch directly into demo playback")
        print("  --help,     -h      Show CLI help")
        os.exit(0)
    else
        i = i + 1
    end
end

run_tui(start_octave, start_wave, auto_demo)
os.exit(0)
