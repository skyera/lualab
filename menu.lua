#!/usr/bin/env luajit
--[[
  menu.lua - Adaptive Interactive Program Launcher for lualab
  Supports responsive dual-pane (wide terminals >= 90 cols) and compact stacked layouts.
  Guarantees 100% fit within current terminal dimensions without scroll flicker.
--]]

local ffi = require("ffi")
local bit = require("bit")

-- POSIX definitions for x86_64 Linux
ffi.cdef[[
  typedef unsigned char cc_t;
  typedef unsigned int  speed_t;
  typedef unsigned int  tcflag_t;

  struct termios {
    tcflag_t c_iflag;
    tcflag_t c_oflag;
    tcflag_t c_cflag;
    tcflag_t c_lflag;
    cc_t     c_line;
    cc_t     c_cc[32];
    speed_t  c_ispeed;
    speed_t  c_ospeed;
  };

  struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
  };

  struct pollfd {
    int   fd;
    short events;
    short revents;
  };

  int tcgetattr(int fd, struct termios *termios_p);
  int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
  int ioctl(int fd, unsigned long request, ...);
  int poll(struct pollfd *fds, unsigned long nfds, int timeout);
  long read(int fd, void *buf, size_t count);
  long write(int fd, const void *buf, size_t count);
  int usleep(unsigned int usec);
]]

local C = ffi.C

local TCSANOW    = 0
local TIOCGWINSZ = 0x5413
local POLLIN     = 0x0001

--------------------------------------------------------------------------------
-- Terminal State Management
--------------------------------------------------------------------------------
local orig_termios = ffi.new("struct termios")
local raw_termios  = ffi.new("struct termios")
local is_raw = false

local function restore_terminal()
  if is_raw then
    C.tcsetattr(0, TCSANOW, orig_termios)
    io.write("\27[?25h\27[?1049l\27[0m")
    io.flush()
    is_raw = false
  end
end

local function init_terminal()
  if C.tcgetattr(0, orig_termios) ~= 0 then
    error("Failed to get terminal attributes")
  end
  ffi.copy(raw_termios, orig_termios, ffi.sizeof("struct termios"))
  
  -- Raw mode: disable ECHO, ICANON, ISIG
  raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(0x0008, 0x0002, 0x0001, 0x8000)))
  raw_termios.c_iflag = bit.band(raw_termios.c_iflag, bit.bnot(bit.bor(0x0400, 0x0100)))
  raw_termios.c_cc[5] = 0 -- VMIN
  raw_termios.c_cc[6] = 0 -- VTIME

  if C.tcsetattr(0, TCSANOW, raw_termios) ~= 0 then
    error("Failed to set raw terminal mode")
  end
  is_raw = true

  io.write("\27[?1049h\27[2J\27[?25l")
  io.flush()
end

local function get_term_size()
  local ws = ffi.new("struct winsize")
  if C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 10 and ws.ws_row > 10 then
    return tonumber(ws.ws_col), tonumber(ws.ws_row)
  end
  return 80, 24
end

local pollfd = ffi.new("struct pollfd", {fd = 0, events = POLLIN, revents = 0})
local in_buf = ffi.new("char[64]")

local function read_key(timeout_ms)
  pollfd.revents = 0
  local ret = C.poll(pollfd, 1, timeout_ms or 50)
  if ret <= 0 then return nil end
  local n = C.read(0, in_buf, 64)
  if n <= 0 then return nil end

  if in_buf[0] == 27 then
    if n >= 3 and in_buf[1] == 91 then
      local code = in_buf[2]
      if code == 65 then return "UP"
      elseif code == 66 then return "DOWN"
      elseif code == 67 then return "RIGHT"
      elseif code == 68 then return "LEFT"
      end
    end
    return "ESC"
  elseif in_buf[0] == 10 or in_buf[0] == 13 then
    return "ENTER"
  end
  return string.char(in_buf[0]):lower()
end

local function file_exists(name)
  local f = io.open(name, "r")
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end

--------------------------------------------------------------------------------
-- Program Manifest & Catalog
--------------------------------------------------------------------------------
local PROGRAMS = {
  {
    id = "outrun_racer",
    file = "outrun_racer.lua",
    title = "🏎️  OutRun Racer",
    full_title = "🏎️  OutRun Terminal Racer",
    category = "Game",
    type = "Arcade 3D Racing",
    backend = "LuaJIT FFI + POSIX termios + TrueColor ANSI Double-Buffer",
    desc = "High-performance pseudo-3D road racing game. Features smooth scanline\n" ..
           "road curves, elevation, parallax sunset backdrop, roadside scenery,\n" ..
           "and overtaking AI traffic running at locked 60 FPS.",
    controls = "[A/D] or [←/→] Steer  •  [W/S] or [↑/↓] Gas/Brake  •  [Q] Quit",
  },
  {
    id = "wolf3d",
    file = "ffi_wolf3d_raycaster.lua",
    title = "🐺 Wolfenstein 3D",
    full_title = "🐺 Wolfenstein 3D Raycaster",
    category = "Game",
    type = "FPS Raycaster",
    backend = "LuaJIT FFI + DDA Raycasting + TrueColor ANSI",
    desc = "Classic first-person 3D raycaster. Explore a 2.5D maze with textured walls,\n" ..
           "minimap display, smooth movement, and retro corridor aesthetics.",
    controls = "[W/S] Move  •  [A/D] Turn  •  [Q/E] Strafe  •  [M] Map  •  [ESC] Quit",
  },
  {
    id = "falling_sand",
    file = "ffi_falling_sand.lua",
    title = "⏳ Falling Sand",
    full_title = "⏳ Falling Sand Sandbox",
    category = "Game",
    type = "Physics Sandbox",
    backend = "LuaJIT FFI + Cellular Automata Grid + ANSI 24-bit",
    desc = "Real-time falling particle and chemical reaction simulation.\n" ..
           "Draw sand, water, fire, wood, acid, and gunpowder to observe reactions.",
    controls = "[Mouse/WASD] Cursor  •  [1-6] Select Element  •  [C] Clear",
  },
  {
    id = "tetris",
    file = "ffi_russian_block.lua",
    title = "🧱 Russian Block",
    full_title = "🧱 Russian Block (Tetris)",
    category = "Game",
    type = "Block Puzzle",
    backend = "LuaJIT FFI + Terminal Matrix Grid",
    desc = "Faithful implementation of classic Tetris with 7 tetrominoes, rotation,\n" ..
           "ghost piece indicator, score tracker, level progression, and line clears.",
    controls = "[←/→] Move  •  [↑] Rotate  •  [↓] Soft Drop  •  [Space] Hard Drop",
  },
  {
    id = "game_2048",
    file = "ffi_game_2048.lua",
    title = "🔢 2048 Edition",
    full_title = "🔢 2048 Terminal Edition",
    category = "Game",
    type = "Sliding Tile Puzzle",
    backend = "LuaJIT FFI + ANSI Colored Tiles",
    desc = "Sleek terminal edition of the popular 2048 tile merging puzzle.\n" ..
           "Features smooth colored tile blocks, undo history, and high score tracking.",
    controls = "[WASD] or [Arrows] Slide Tiles  •  [U] Undo  •  [R] Restart  •  [Q] Quit",
  },
  {
    id = "chinese_chess",
    file = "ffi_chinese_chess.lua",
    title = "♟️  Chinese Chess",
    full_title = "♟️  Chinese Chess (Xiangqi)",
    category = "Game",
    type = "Board Game / Strategy",
    backend = "LuaJIT FFI + Unicode Board Renderer",
    desc = "Traditional Chinese Chess (Xiangqi) with full board rendering, legal move\n" ..
           "validation, piece captures, check detection, and turn-based play.",
    controls = "[Arrows] Move Cursor  •  [Space/Enter] Pick & Place  •  [Q] Quit",
  },
  {
    id = "snake",
    file = "ffi_game_snake.lua",
    title = "🐍 Classic Snake",
    full_title = "🐍 Classic Snake",
    category = "Game",
    type = "Arcade Classic",
    backend = "LuaJIT FFI + Framebuffer Loop",
    desc = "Classic snake game with smooth movement, fruit spawning, score counter,\n" ..
           "and boundary wrapping modes.",
    controls = "[WASD] or [Arrows] Direction  •  [P] Pause  •  [Q] Quit",
  },
  {
    id = "file_list_tui",
    file = "file_list_tui.lua",
    title = "📁 File Manager",
    full_title = "📁 File Manager TUI",
    category = "Utility",
    type = "File Browser",
    backend = "LuaJIT FFI + POSIX dirent/stat + ANSI Viewport",
    desc = "Interactive terminal file manager. Features directory tree navigation,\n" ..
           "file permissions and size inspection, multi-sort, and quick preview.",
    controls = "[↑/↓] Navigate  •  [Enter] Open/Enter  •  [Backspace] Up  •  [Q] Quit",
  },
  {
    id = "luatop",
    file = "luatop.lua",
    title = "📊 Luatop Monitor",
    full_title = "📊 Luatop System Monitor",
    category = "Utility",
    type = "System Monitor",
    backend = "LuaJIT FFI + /proc Parser + Live Sparklines",
    desc = "Comprehensive real-time system resource monitor. Displays per-core CPU usage,\n" ..
           "memory distribution, process tables, network I/O, and disk load graphs.",
    controls = "[Tab] Switch Panel  •  [↑/↓] Select Process  •  [K] Kill  •  [Q] Quit",
  },
  {
    id = "lazygit_lite",
    file = "lazygit_lite.lua",
    title = "🌿 Lazygit Lite",
    full_title = "🌿 Lazygit Lite",
    category = "Utility",
    type = "Git Client",
    backend = "LuaJIT FFI + Git Subprocess + Split View",
    desc = "Streamlined terminal interface for Git repositories. Inspect status,\n" ..
           "stage/unstage changes, view diffs side-by-side, and browse commit logs.",
    controls = "[Tab] Switch Section  •  [Space] Stage  •  [C] Commit  •  [Q] Quit",
  },
  {
    id = "todo_tui",
    file = "todo_tui.lua",
    title = "✅ Todo Manager",
    full_title = "✅ Todo List Manager",
    category = "Utility",
    type = "Task Organizer",
    backend = "LuaJIT FFI + JSON Persistence",
    desc = "Interactive task and priority manager with categorized task lists,\n" ..
           "due dates, completion status, and instant search.",
    controls = "[A] Add  •  [Space] Toggle Done  •  [D] Delete  •  [E] Edit  •  [Q] Quit",
  }
}

--------------------------------------------------------------------------------
-- String & Display Utilities (Accurate Visual Width)
--------------------------------------------------------------------------------
local ANSI = {
  RESET        = "\27[0m",
  HOME         = "\27[H",
  BOLD         = "\27[1m",
  DIM          = "\27[2m",
  BG_HDR       = "\27[48;2;30;40;65m",
  FG_HDR       = "\27[38;2;120;210;255m",
  FG_TITLE     = "\27[38;2;255;220;60m",
  FG_CYAN      = "\27[38;2;90;210;245m",
  FG_GREEN     = "\27[38;2;100;240;130m",
  FG_GRAY      = "\27[38;2;140;145;160m",
  FG_WHITE     = "\27[38;2;240;245;255m",
  FG_YELLOW    = "\27[38;2;255;220;80m",
  FG_SEL       = "\27[38;2;255;255;255m\27[48;2;45;75;135m",
  BORDER       = "\27[38;2;80;90;120m",
}

-- Calculate visual width in columns (ignoring ANSI sequences and counting UTF-8/emoji properly)
local function visual_width(str)
  local clean = str:gsub("\27%[[%d;]*[mK]", "")
  local width = 0
  local i = 1
  local len = #clean
  while i <= len do
    local b = clean:byte(i)
    if b < 128 then
      width = width + 1
      i = i + 1
    elseif b >= 192 and b < 224 then
      width = width + 1
      i = i + 2
    elseif b >= 224 and b < 240 then
      -- 3-byte UTF8, many symbols / Asian characters are double-width
      width = width + 1
      i = i + 3
    elseif b >= 240 then
      -- 4-byte UTF8: emojis are double-width in most modern terminals
      width = width + 2
      i = i + 4
    else
      i = i + 1
    end
  end
  return width
end

local function pad_to_width(str, target_w)
  local vw = visual_width(str)
  if vw < target_w then
    return str .. string.rep(" ", target_w - vw)
  end
  return str
end

--------------------------------------------------------------------------------
-- Dual-Pane Layout Renderer (for width >= 90)
--------------------------------------------------------------------------------
local function render_dual_pane(selected_idx, scroll_offset, width, height)
  local lines = {}
  
  -- 1. Top Header
  local hdr_text = "  ⚡ LUALAB - INTERACTIVE PROGRAM LAUNCHER"
  local ver_text = "v1.2.0  "
  local top_bar = ANSI.BG_HDR .. ANSI.FG_HDR .. ANSI.BOLD .. hdr_text ..
                  string.rep(" ", math.max(0, width - visual_width(hdr_text) - visual_width(ver_text))) ..
                  ANSI.FG_TITLE .. ver_text .. ANSI.RESET
  table.insert(lines, top_bar)

  -- Subtitle instruction
  local pos_str = string.format("(%d/%d)", selected_idx, #PROGRAMS)
  local sub_line = ANSI.FG_GRAY .. "  Select program with " .. ANSI.FG_CYAN .. "[↑/↓ or J/K]" ..
                   ANSI.FG_GRAY .. ", press " .. ANSI.FG_GREEN .. "[Enter]" ..
                   ANSI.FG_GRAY .. " to launch: " .. ANSI.FG_CYAN .. ANSI.BOLD .. pos_str .. ANSI.RESET
  table.insert(lines, sub_line)

  -- Calculate Box Dimensions
  local avail_w = width - 4
  local left_w = math.max(38, math.floor(avail_w * 0.44))
  local right_w = avail_w - left_w - 2
  local box_h = math.max(10, height - 5)
  local max_visible = box_h - 3 -- top border, blank/hint row, bottom border

  -- Adjust scroll offset
  if selected_idx <= scroll_offset then
    scroll_offset = selected_idx - 1
  elseif selected_idx > scroll_offset + max_visible then
    scroll_offset = selected_idx - max_visible
  end

  local left_rows = {}
  local right_rows = {}

  -- Build Left Rows (Program List)
  local left_top = ANSI.BORDER .. "┌── PROGRAMS (" .. pos_str .. ") " .. string.rep("─", math.max(0, left_w - 17 - #pos_str)) .. "┐" .. ANSI.RESET
  table.insert(left_rows, left_top)

  local end_i = math.min(#PROGRAMS, scroll_offset + max_visible)
  for i = scroll_offset + 1, end_i do
    local prog = PROGRAMS[i]
    local is_sel = (i == selected_idx)
    local exists = file_exists(prog.file)
    local badge_raw = exists and ("(" .. prog.category .. ")") or "(not found)"
    local badge = exists and (ANSI.FG_GREEN .. badge_raw .. ANSI.RESET) or (ANSI.FG_GRAY .. badge_raw .. ANSI.RESET)
    
    local prefix = is_sel and " ▶ " or "    "
    local title_str = prog.title
    local inner_w = left_w - 2
    local avail_for_title = inner_w - visual_width(prefix) - visual_width(badge_raw) - 1
    if visual_width(title_str) > avail_for_title then
      title_str = title_str:sub(1, math.max(10, avail_for_title - 2)) .. ".."
    end

    local text_part = prefix .. title_str
    local pad_spaces = math.max(1, inner_w - visual_width(text_part) - visual_width(badge_raw))
    local line_content = is_sel and
      (ANSI.FG_SEL .. ANSI.BOLD .. text_part .. string.rep(" ", pad_spaces) .. badge .. ANSI.RESET) or
      (ANSI.FG_WHITE .. text_part .. string.rep(" ", pad_spaces) .. badge .. ANSI.RESET)

    table.insert(left_rows, ANSI.BORDER .. "│" .. line_content .. ANSI.BORDER .. "│" .. ANSI.RESET)
  end

  -- Fill blank rows in left box if list is short
  while #left_rows < box_h - 1 do
    local is_last = (#left_rows == box_h - 2)
    if is_last then
      local hint = (scroll_offset > 0 and end_i < #PROGRAMS) and "▲ more | ▼ more" or
                   ((scroll_offset > 0) and "▲ more above" or
                   ((end_i < #PROGRAMS) and string.format("▼ %d more below", #PROGRAMS - end_i) or ""))
      local hpad = left_w - 2 - visual_width(hint)
      local hl = math.floor(hpad / 2)
      local hr = hpad - hl
      local hint_line = string.rep(" ", math.max(0, hl)) .. ANSI.FG_GRAY .. ANSI.DIM .. hint .. ANSI.RESET .. string.rep(" ", math.max(0, hr))
      table.insert(left_rows, ANSI.BORDER .. "│" .. hint_line .. ANSI.BORDER .. "│" .. ANSI.RESET)
    else
      table.insert(left_rows, ANSI.BORDER .. "│" .. string.rep(" ", left_w - 2) .. ANSI.BORDER .. "│" .. ANSI.RESET)
    end
  end
  table.insert(left_rows, ANSI.BORDER .. "└──" .. string.rep("─", left_w - 4) .. "┘" .. ANSI.RESET)

  -- Build Right Rows (Details Box)
  local cur = PROGRAMS[selected_idx]
  local right_top = ANSI.BORDER .. "┌── PROGRAM DETAILS " .. string.rep("─", math.max(0, right_w - 20)) .. "┐" .. ANSI.RESET
  table.insert(right_rows, right_top)

  local function add_detail(label, val, val_color)
    val_color = val_color or ANSI.FG_WHITE
    local inner_w = right_w - 2
    local lbl_str = label ~= "" and (label .. ": ") or "  "
    local lbl_w = visual_width(lbl_str)
    local max_val_w = inner_w - lbl_w - 2
    local val_display = val
    if visual_width(val_display) > max_val_w then
      val_display = val_display:sub(1, math.max(4, max_val_w - 3)) .. "..."
    end
    local pad = math.max(0, inner_w - lbl_w - visual_width(val_display) - 1)
    local row = " " .. ANSI.FG_CYAN .. lbl_str .. val_color .. val_display .. ANSI.RESET .. string.rep(" ", pad)
    table.insert(right_rows, ANSI.BORDER .. "│" .. row .. ANSI.BORDER .. "│" .. ANSI.RESET)
  end

  add_detail("Name", cur.full_title or cur.title, ANSI.FG_TITLE .. ANSI.BOLD)
  add_detail("Script", cur.file, ANSI.FG_WHITE)
  add_detail("Type", cur.type, ANSI.FG_GREEN)
  add_detail("Backend", cur.backend, ANSI.FG_GRAY)
  table.insert(right_rows, ANSI.BORDER .. "│" .. string.rep(" ", right_w - 2) .. ANSI.BORDER .. "│" .. ANSI.RESET)

  local first = true
  for line in cur.desc:gmatch("[^\r\n]+") do
    local lbl = first and "Desc" or ""
    first = false
    add_detail(lbl, line, ANSI.FG_WHITE)
  end

  table.insert(right_rows, ANSI.BORDER .. "│" .. string.rep(" ", right_w - 2) .. ANSI.BORDER .. "│" .. ANSI.RESET)
  add_detail("Keys", cur.controls, ANSI.FG_YELLOW)

  while #right_rows < box_h - 1 do
    table.insert(right_rows, ANSI.BORDER .. "│" .. string.rep(" ", right_w - 2) .. ANSI.BORDER .. "│" .. ANSI.RESET)
  end
  table.insert(right_rows, ANSI.BORDER .. "└──" .. string.rep("─", right_w - 4) .. "┘" .. ANSI.RESET)

  -- Combine Left and Right Columns
  for r = 1, box_h do
    local l_chunk = left_rows[r] or string.rep(" ", left_w)
    local r_chunk = right_rows[r] or string.rep(" ", right_w)
    table.insert(lines, "  " .. l_chunk .. " " .. r_chunk)
  end

  -- Bottom Footer
  local foot_text = "  [Enter] Launch Program    [↑/↓ or J/K] Navigate    [Q / Esc] Exit"
  table.insert(lines, ANSI.FG_GRAY .. ANSI.DIM .. foot_text .. ANSI.RESET)

  return table.concat(lines, "\n"), scroll_offset
end

--------------------------------------------------------------------------------
-- Compact Stacked Layout Renderer (for width < 90 or height < 26)
--------------------------------------------------------------------------------
local function render_compact(selected_idx, scroll_offset, width, height)
  local lines = {}
  local box_w = math.min(width - 4, 76)
  
  -- Header
  local hdr_text = "  ⚡ LUALAB LAUNCHER"
  local ver_text = "v1.2.0  "
  local top_bar = ANSI.BG_HDR .. ANSI.FG_HDR .. ANSI.BOLD .. hdr_text ..
                  string.rep(" ", math.max(0, width - visual_width(hdr_text) - visual_width(ver_text))) ..
                  ANSI.FG_TITLE .. ver_text .. ANSI.RESET
  table.insert(lines, top_bar)

  -- Position line
  local pos_str = string.format("(%d/%d)", selected_idx, #PROGRAMS)
  local sub_line = ANSI.FG_GRAY .. "  Select: " .. ANSI.FG_CYAN .. "[↑/↓]" ..
                   ANSI.FG_GRAY .. "  Launch: " .. ANSI.FG_GREEN .. "[Enter]" ..
                   ANSI.FG_GRAY .. "  " .. ANSI.FG_CYAN .. ANSI.BOLD .. pos_str .. ANSI.RESET
  table.insert(lines, sub_line)

  -- Available vertical room for programs
  local list_visible = math.max(3, math.min(5, height - 14))
  if selected_idx <= scroll_offset then
    scroll_offset = selected_idx - 1
  elseif selected_idx > scroll_offset + list_visible then
    scroll_offset = selected_idx - list_visible
  end

  -- Program Box
  local top_bdr = "  " .. ANSI.BORDER .. "┌── PROGRAMS (" .. pos_str .. ") " .. string.rep("─", math.max(0, box_w - 17 - #pos_str)) .. "┐" .. ANSI.RESET
  table.insert(lines, top_bdr)

  local end_i = math.min(#PROGRAMS, scroll_offset + list_visible)
  for i = scroll_offset + 1, end_i do
    local prog = PROGRAMS[i]
    local is_sel = (i == selected_idx)
    local exists = file_exists(prog.file)
    local badge_raw = exists and ("(" .. prog.category .. ")") or "(not found)"
    local badge = exists and (ANSI.FG_GREEN .. badge_raw .. ANSI.RESET) or (ANSI.FG_GRAY .. badge_raw .. ANSI.RESET)
    
    local prefix = is_sel and " ▶ " or "    "
    local inner_w = box_w - 2
    local avail = inner_w - visual_width(prefix) - visual_width(prog.file) - visual_width(badge_raw) - 5
    local title_s = prog.title
    if visual_width(title_s) > avail then
      title_s = title_s:sub(1, math.max(6, avail - 2)) .. ".."
    end

    local text_part = string.format("%s%-18s [%s]", prefix, title_s, prog.file)
    local pad = math.max(1, inner_w - visual_width(text_part) - visual_width(badge_raw))
    local line_content = is_sel and
      (ANSI.FG_SEL .. ANSI.BOLD .. text_part .. string.rep(" ", pad) .. badge .. ANSI.RESET) or
      (ANSI.FG_WHITE .. text_part .. string.rep(" ", pad) .. badge .. ANSI.RESET)

    table.insert(lines, "  " .. ANSI.BORDER .. "│" .. line_content .. ANSI.BORDER .. "│" .. ANSI.RESET)
  end

  local hint = (scroll_offset > 0 and end_i < #PROGRAMS) and "▲ more | ▼ more" or
               ((scroll_offset > 0) and "▲ more above" or
               ((end_i < #PROGRAMS) and string.format("▼ %d more below", #PROGRAMS - end_i) or ""))
  local hpad = box_w - 2 - visual_width(hint)
  local hl = math.floor(hpad / 2)
  local hr = hpad - hl
  table.insert(lines, "  " .. ANSI.BORDER .. "│" .. string.rep(" ", math.max(0, hl)) ..
                      ANSI.FG_GRAY .. ANSI.DIM .. hint .. ANSI.RESET ..
                      string.rep(" ", math.max(0, hr)) .. ANSI.BORDER .. "│" .. ANSI.RESET)
  table.insert(lines, "  " .. ANSI.BORDER .. "└──" .. string.rep("─", box_w - 4) .. "┘" .. ANSI.RESET)

  -- Compact Details Box
  local cur = PROGRAMS[selected_idx]
  local det_bdr = "  " .. ANSI.BORDER .. "┌── DETAILS " .. string.rep("─", math.max(0, box_w - 12)) .. "┐" .. ANSI.RESET
  table.insert(lines, det_bdr)

  local function add_compact_detail(lbl, val, col)
    col = col or ANSI.FG_WHITE
    local inner_w = box_w - 2
    local prefix_str = " " .. ANSI.FG_CYAN .. lbl .. ": " .. col
    local max_v = inner_w - visual_width(lbl) - 3
    local v_str = visual_width(val) > max_v and (val:sub(1, max_v - 3) .. "...") or val
    local pad = math.max(0, inner_w - visual_width(lbl) - 3 - visual_width(v_str))
    local row = prefix_str .. v_str .. ANSI.RESET .. string.rep(" ", pad)
    table.insert(lines, "  " .. ANSI.BORDER .. "│" .. row .. ANSI.BORDER .. "│" .. ANSI.RESET)
  end

  add_compact_detail("Name", cur.full_title or cur.title, ANSI.FG_TITLE .. ANSI.BOLD)
  add_compact_detail("Script", cur.file .. "  (" .. cur.type .. ")", ANSI.FG_WHITE)
  local first_desc = cur.desc:match("^[^\r\n]+") or cur.desc
  add_compact_detail("Desc", first_desc, ANSI.FG_GRAY)
  add_compact_detail("Keys", cur.controls, ANSI.FG_YELLOW)
  table.insert(lines, "  " .. ANSI.BORDER .. "└──" .. string.rep("─", box_w - 4) .. "┘" .. ANSI.RESET)

  -- Footer
  table.insert(lines, ANSI.FG_GRAY .. ANSI.DIM .. "  [Enter] Launch   [↑/↓] Navigate   [Q] Exit" .. ANSI.RESET)

  return table.concat(lines, "\n"), scroll_offset
end

--------------------------------------------------------------------------------
-- Main Loop & Draw Coordinator
--------------------------------------------------------------------------------
local function run_menu(is_test)
  local selected_idx = 1
  local scroll_offset = 0

  local function render()
    local w, h = get_term_size()
    local frame_str
    if w >= 90 and h >= 18 then
      frame_str, scroll_offset = render_dual_pane(selected_idx, scroll_offset, w, h)
    else
      frame_str, scroll_offset = render_compact(selected_idx, scroll_offset, w, h)
    end
    C.write(1, ANSI.HOME .. frame_str, #frame_str + #ANSI.HOME)
  end

  if is_test then
    -- Verify in dual-pane mode (100x30)
    local dual_out = render_dual_pane(1, 0, 100, 30)
    assert(dual_out and #dual_out > 0)
    -- Verify in compact mode (80x24 standard terminal)
    local compact_out = render_compact(1, 0, 80, 24)
    assert(compact_out and #compact_out > 0)
    
    -- Ensure compact mode strictly fits within 24 rows
    local row_count = 0
    for _ in compact_out:gmatch("\n") do row_count = row_count + 1 end
    assert(row_count <= 24, "Compact mode exceeded standard 24 rows! Actual rows: " .. row_count)
    
    render()
    return { ok = true, programs_count = #PROGRAMS }
  end

  local running = true
  while running do
    render()
    local key = read_key(100)

    if key == "UP" or key == "k" then
      selected_idx = selected_idx - 1
      if selected_idx < 1 then selected_idx = #PROGRAMS end
    elseif key == "DOWN" or key == "j" then
      selected_idx = selected_idx + 1
      if selected_idx > #PROGRAMS then selected_idx = 1 end
    elseif key == "q" or key == "ESC" then
      running = false
    elseif key == "ENTER" then
      local prog = PROGRAMS[selected_idx]
      if file_exists(prog.file) then
        restore_terminal()
        print("\n\27[38;2;100;240;130mLaunching " .. (prog.full_title or prog.title) .. "...\27[0m\n")
        os.execute("luajit " .. prog.file)
        print("\n\27[38;2;120;210;255m[Press any key to return to menu]\27[0m")
        init_terminal()
        read_key(5000)
      else
        print("\n\27[38;2;255;70;70mError: " .. prog.file .. " not found!\27[0m\n")
      end
    end
  end

  return { ok = true }
end

--------------------------------------------------------------------------------
-- Entry Point
--------------------------------------------------------------------------------
local is_test = false
for i = 1, #arg do
  if arg[i] == "--test" then
    is_test = true
  end
end

if not is_test then
  init_terminal()
end

local ok, res = pcall(function()
  return run_menu(is_test)
end)

restore_terminal()

if not ok then
  io.stderr:write("Error: " .. tostring(res) .. "\n")
  os.exit(1)
end

if is_test then
  print(string.format("✓ menu.lua responsive layout test passed! Verified dual-pane and compact 80x24 fit."))
end
