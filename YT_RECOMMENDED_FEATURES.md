# yt.lua — Recommended Features & Roadmap Specification

This document details the recommended feature roadmap and design specifications for [`yt.lua`](file:///D:/test/lualab/yt.lua), expanding its capabilities across audio streaming, playback controls, sound enhancement, and offline library management.

---

## 1. Feature Priority & Implementation Matrix

| ID | Feature | Category | Hotkey / CLI Flag | Complexity | User Value | Status / Priority |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **F-1** | **Numerical Percentage Jump Seek** | Playback Navigation | `[0]`–`[9]` | Low | High | **P1 (Immediate)** |
| **F-2** | **Playback Speed Multiplier** | Playback Controls | `[` / `]` | Low | High | **✓ Completed** |
| **F-3** | **Infinite YouTube Mix / Radio Mode** | Streaming Engine | `[r]` / `--radio` | Medium | Very High | **✓ Completed** |
| **F-4** | **Sleep Timer / Auto-Pause** | Convenience | `[z]` / `--sleep` | Low | High | **P2** |
| **F-5** | **Audio Equalizer & Loudness Normalizer** | Audio DSP | `[e]` / `--eq` | Medium | High | **✓ Completed** |
| **F-6** | **Local Starred Favorites & Playlists** | Library & Organization | `[*]` / `[F]` | Medium | High | **✓ Completed** |
| **F-7** | **Offline Downloaded Library Browser** | Offline Mode | `[L]` / `--local` | Medium | Medium | **P3** |

---

## 2. Detailed Feature Specifications

### F-1: Numerical Percentage Jump Seek (`[0]`–`[9]`)

#### Overview
Adopts the industry-standard YouTube keyboard shortcuts for instantaneous track seeking:
- `0`: Jump to beginning (`0%` / `00:00`)
- `1` through `9`: Jump directly to `10%`, `20%`, ..., `90%` of track duration.

#### Architectural Design
- Uses mpv IPC `seek` command with `absolute-percent`:
  ```json
  {"command": ["seek", 50, "absolute-percent"]}
  ```
- Falls back to `(percent / 100) * duration` when `duration` is known.
- Resets rolling caption state (`self.cc_state = { prev_last_line = "", prev_displayed = "" }`) so subtitles re-sync instantly.

#### TUI Visual Feedback
```text
 Status: Seeked to 50% (01:45 / 03:30)
```

---

### F-2: Real-Time Playback Speed Control (`[` / `]`)

#### Overview
Allows variable speed playback (0.5x, 0.75x, 1.0x, 1.25x, 1.5x, 1.75x, 2.0x) with pitch preservation via mpv's `scaletempo2` filter. Indispensable for podcasts, educational content, interviews, and speed-listening.

#### Controls
- `[`: Decrease speed by `0.25x` (clamped to minimum `0.5x`).
- `]`: Increase speed by `0.25x` (clamped to maximum `2.5x`).
- `Backspace` (in speed modal) or `{`: Reset speed to `1.0x`.

#### Mini-Player & Header Display
```text
 ==============================================================================
  YouTube Terminal Viewer | [MUSIC] | [AUTO: ON] | [SPEED: 1.25x] | Guest
  Search: "lex fridman podcast"  (Playing: Lex Fridman #400)
 ------------------------------------------------------------------------------
  [▶] Playing: Lex Fridman #400 (Resumed 14:20) [1.25x]
  [00:14:20 / 02:45:10] [=======>------------------------]  Vol: 90%  Speed: 1.25x
```

---

### F-3: Infinite YouTube Mix / Radio Mode (`[r]` / `--radio`)

#### Overview
Currently, auto-play (`[a]`) only advances down the static 25 search results. When the list ends, playback stops.
Infinite Radio mode queries YouTube's related video recommendations / Mix playlist (`RD<video_id>`) for the currently playing track and automatically queues continuous similar tracks.

#### Mechanics & Fallback
1. Query yt-dlp with the mix URL:
   ```bash
   yt-dlp --dump-json --flat-playlist "https://www.youtube.com/watch?v=<VIDEO_ID>&list=RD<VIDEO_ID>"
   ```
2. When offline or yt-dlp is restricted, extract related video links from the initial HTML scrape (`"compactVideoRenderer"` or `"watch-next"` payload).
3. Deduplicate against playback history (`history.json`) and existing queue.
4. Auto-populate next 5 tracks into the Up-Next queue whenever queue length falls below 2.

#### Visual Mockup
```text
 ==============================================================================
  YouTube Terminal Viewer | [MUSIC] | [RADIO: ON] | [QUEUE: 5] | Guest
  Search: "synthwave chill"  (Radio: auto-queued 5 similar tracks)
 ------------------------------------------------------------------------------
   01. Timecop1983 - Lovers (feat. SEAWAVES)           | Timecop1983    | 04:22
   02. The Midnight - Sunset                           | The Midnight   | 05:25
   03. FM-84 - Running in the Night                    | FM-84          | 04:30
 > 04. Gunship - Tech Noir                             | GUNSHIP        | 04:58
```

---

### F-4: Sleep Timer / Auto-Pause (`[z]` / `--sleep`)

#### Overview
Countdown timer that pauses playback (and optionally terminates the player) after a specified duration. Ideal for bedtime listening, focus sessions (Pomodoro), and background ambient sound.

#### Sleep Modal UI Mockup (`[z]`)
```text
+------------------------------------------------------------+
| [z] Set Sleep Timer                                        |
|                                                            |
|  ( ) Off                                                   |
|  ( ) 15 Minutes                                            |
|  (*) 30 Minutes  [24:18 remaining]                         |
|  ( ) 45 Minutes                                            |
|  ( ) 60 Minutes                                            |
|  ( ) 90 Minutes                                            |
|  ( ) Custom minutes...                                     |
|                                                            |
|  Action on timer expiry: [Pause Playback] / Exit Player    |
|                                                            |
|  [Enter] Confirm   [Up/Down] Navigate   [Esc] Cancel       |
+------------------------------------------------------------+
```

#### Status Line Indicator
```text
 [▶] Playing: Lofi Rain Beats  | Vol: 80% | ◷ Sleep in 24m
```

---

### F-5: Audio Equalizer & Loudness Normalization (`[e]` / `--eq`)

#### Overview
Dynamic DSP audio filter switching using mpv's `af` chain via IPC without interrupting playback:
- **Night Mode / Loudness Normalizer** (`dynaudnorm=f=150:g=15` or `loudnorm`):
  Eliminates volume spikes between quiet indie music and loud production tracks.
- **Bass Boost** (`equalizer=f=64:t=q:w=1:g=6:f=125:t=q:w=1:g=4`):
  Punchy low-end enhancement for electronic and hip-hop.
- **Vocal Clarity / Podcast** (`equalizer=f=1000:t=q:w=1:g=3:f=3000:t=q:w=1:g=4`):
  Cuts harsh rumble and enhances spoken voice frequencies.
- **Lo-Fi / Vinyl Warmth**: Subtle high-cut filter (`lowpass=f=4500`).

#### Quick EQ Modal UI (`[e]`)
```text
+------------------------------------------------------------+
| [e] Audio Equalizer & Sound Enhancement                    |
|                                                            |
|  ( ) Flat / Bypass (Original Audio)                        |
|  (*) Loudness Normalizer (Night Mode - Dynamic Volume)     |
|  ( ) Bass Boost (+6dB low end)                             |
|  ( ) Vocal Clarity (Podcasts & Interviews)                 |
|  ( ) Lo-Fi Warmth (Analog high-cut filter)                 |
|                                                            |
|  [Enter] Apply Preset   [Up/Down] Select   [Esc] Dismiss   |
+------------------------------------------------------------+
```

---

### F-6: Local Starred Favorites & Saved Playlists (`[*]`, `[F]`)

#### Overview
Allows users to save favorite tracks locally without needing a YouTube account or browser session cookies:
- `[*]`: Star / un-star selected track or currently playing track.
- `[F]`: Toggle view mode between **Search Results**, **Playback History**, and **Starred Favorites**.
- Saves persistently in `<cache_dir>/favorites.json`.
- Exportable to standard `.m3u8` playlist files.

#### Starred Track List Indicator
```text
  01. ★ Lofi Girl - 1 A.M Study Session               | Lofi Girl      | 01:05:22
  02. ★ Tycho - Awake                                 | Tycho          | 04:43
  03.   The Midnight - Days of Thunder                | The Midnight   | 05:21
```

---

### F-7: Offline Downloaded Library Browser (`[L]` / `--local`)

#### Overview
Direct in-app access to downloaded tracks in `./downloads/`:
- Lists all downloaded `.mp3` and `.mp4` files.
- Plays directly from local disk via mpv with zero network overhead.
- Supports offline search/filtering across cached file titles.
- Works 100% offline without network connectivity or yt-dlp calls.

---

## 3. Verification & Validation Plan (per AGENTS.md)

1. **Unit & Logic Tests (`yt.lua --test`)**:
   - Numerical percentage conversion formula: `pos = (pct / 100) * dur`.
   - Speed clamping: `min 0.5x <= speed <= max 2.5x`.
   - Sleep timer countdown math and expiry callback trigger.
   - Equalizer filter string generation matching valid mpv `af` syntax.
   - Favorites JSON serialization, deduplication, and un-star operations.

2. **IPC Integration Verification**:
   - Send `seek`, `speed`, and `af` IPC payloads to mpv background process and assert successful response without process crash or disconnect.

3. **TUI Differential Refresh & Bounds Check**:
   - Verify modal opening/closing adheres to flicker-free row addressing (`\27[Y;XH`).
   - Validate terminal width clamping to `raw_cols - 1` to prevent auto-wrap shifting.
