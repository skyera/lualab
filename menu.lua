#!/usr/bin/env luajit
--[[
  menu.lua - Interactive Program Launcher for lualab
  Lists tools and games with detailed inspect pane and launches them smoothly.
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

--------------------------------------------------------------------------------
-- Program Manifest & Discovery
--------------------------------------------------------------------------------
local PROGRAMS = {
  {
    id = "outrun_racer",
    file = "outrun_racer.lua",
    title = "🏎️  OutRun Terminal Racer",
    category = "Game",
    type = "Arcade 3D Racing",
    backend = "LuaJIT FFI + POSIX termios + TrueColor ANSI Double-Buffer",
    desc = "High-performance pseudo-3D road racing game. Features smooth scanline\n" ..
           "road curves, elevation, parallax sunset backdrop, roadside scenery,\n" ..
           "and overtaking AI traffic running at locked 60 FPS.",
    controls = "[A/D] or [←/→] Steer  •  [W/S] or [↑/↓] Gas/Brake  •  [Q] Quit",
  },
  {
    id = "fzf_preview",
    file = "fzf_preview.lua",
    title = "🔍 FZF File Previewer",
    category = "Utility",
    type = "CLI Productivity",
    backend = "LuaJIT FFI + POSIX pipe/fork / curses",
    desc = "Interactive fuzzy file finder with live split-screen file preview pane\n" ..
           "and real-time search filtering.",
    controls = "Type to search  •  [↑/↓] Navigate  •  [Enter] Select  •  [Esc] Cancel",
  }
}

-- Check if files exist locally
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
-- UI Styling & Rendering
--------------------------------------------------------------------------------
local ANSI = {
  RESET        = "\27[0m",
  HOME         = "\27[H",
  BOLD         = "\27[1m",
  DIM          = "\27[2m",
  INVERSE      = "\27[7m",
  BG_HDR       = "\27[48;2;30;40;65m",
  FG_HDR       = "\27[38;2;120;210;255m",
  FG_TITLE     = "\27[38;2;255;220;60m",
  FG_CYAN      = "\27[38;2;90;210;245m",
  FG_GREEN     = "\27[38;2;100;240;130m",
  FG_GRAY      = "\27[38;2;140;145;160m",
  FG_WHITE     = "\27[38;2;240;245;255m",
  FG_SEL       = "\27[38;2;255;255;255m\27[48;2;45;75;135m",
  BG_BOX       = "\27[48;2;20;24;35m",
  BORDER       = "\27[38;2;80;90;120m",
}

local function pad_line(str, len)
  local visual_len = 0
  local in_escape = false
  for i = 1, #str do
    local b = str:byte(i)
    if b == 27 then
      in_escape = true
    elseif in_escape and b == 109 then -- 'm' terminates ANSI SGR
      in_escape = false
    elseif not in_escape then
      visual_len = visual_len + 1
    end
  end
  if visual_len < len then
    return str .. string.rep(" ", len - visual_len)
  end
  return str
end

local function draw_menu(selected_idx)
  local width, height = get_term_size()
  local lines = {}

  -- 1. Header Bar
  local hdr_text = "  ⚡ LUALAB - INTERACTIVE PROGRAM LAUNCHER"
  local ver_text = "v1.0.0  "
  local hdr_line = ANSI.BG_HDR .. ANSI.FG_HDR .. ANSI.BOLD .. hdr_text ..
                   string.rep(" ", math.max(0, width - #hdr_text - #ver_text)) ..
                   ANSI.FG_TITLE .. ver_text .. ANSI.RESET
  table.insert(lines, hdr_line)
  table.insert(lines, "")

  -- Instructions
  table.insert(lines, ANSI.FG_GRAY .. "  Select a program with " .. ANSI.FG_CYAN .. "[↑/↓]" ..
                      ANSI.FG_GRAY .. " or " .. ANSI.FG_CYAN .. "[J/K]" ..
                      ANSI.FG_GRAY .. ", then press " .. ANSI.FG_GREEN .. "[Enter]" ..
                      ANSI.FG_GRAY .. " to launch:" .. ANSI.RESET)
  table.insert(lines, "")

  -- 2. Program Selection Box
  local box_w = math.min(width - 4, 76)
  local top_bdr = "  " .. ANSI.BORDER .. "┌── AVAILABLE PROGRAMS " .. string.rep("─", math.max(0, box_w - 23)) .. "┐" .. ANSI.RESET
  table.insert(lines, top_bdr)
  table.insert(lines, "  " .. ANSI.BORDER .. "│" .. string.rep(" ", box_w - 2) .. "│" .. ANSI.RESET)

  for i, prog in ipairs(PROGRAMS) do
    local is_sel = (i == selected_idx)
    local exists = file_exists(prog.file)
    local badge_raw = exists and ("(" .. prog.category .. ")") or "(not found)"
    local badge_colored = exists and (ANSI.FG_GREEN .. badge_raw .. ANSI.RESET) or (ANSI.FG_GRAY .. badge_raw .. ANSI.RESET)
    
    local prefix = is_sel and " ▶ " or "    "
    local title_part = prog.title
    local file_part = "[" .. prog.file .. "]"
    
    -- Visual width calculation: prefix(4) + title(24) + file(18) + badge(10) ~ 56
    local left_content = string.format("%s%-24s %-18s ", prefix, title_part, file_part)
    local avail_space = box_w - 2 - #left_content - #badge_raw
    if avail_space < 1 then avail_space = 1 end

    local row_inside = is_sel and
      (ANSI.FG_SEL .. ANSI.BOLD .. left_content .. string.rep(" ", avail_space) .. badge_colored .. ANSI.RESET) or
      (ANSI.FG_WHITE .. left_content .. string.rep(" ", avail_space) .. badge_colored .. ANSI.RESET)

    table.insert(lines, "  " .. ANSI.BORDER .. "│" .. row_inside .. ANSI.BORDER .. "│" .. ANSI.RESET)
  end

  table.insert(lines, "  " .. ANSI.BORDER .. "│" .. string.rep(" ", box_w - 2) .. "│" .. ANSI.RESET)
  table.insert(lines, "  " .. ANSI.BORDER .. "└──" .. string.rep("─", box_w - 4) .. "┘" .. ANSI.RESET)
  table.insert(lines, "")

  -- 3. Program Details Pane
  local cur = PROGRAMS[selected_idx]
  local det_bdr = "  " .. ANSI.BORDER .. "┌── PROGRAM DETAILS " .. string.rep("─", math.max(0, box_w - 20)) .. "┐" .. ANSI.RESET
  table.insert(lines, det_bdr)
  table.insert(lines, "  " .. ANSI.BORDER .. "│" .. string.rep(" ", box_w - 2) .. "│" .. ANSI.RESET)

  local function add_detail(label, val, val_color)
    val_color = val_color or ANSI.FG_WHITE
    local lbl_str = label ~= "" and (label .. ":") or ""
    local left_part = string.format("  %-12s ", lbl_str)
    local max_val_len = box_w - 2 - #left_part
    local val_display = #val > max_val_len and (val:sub(1, max_val_len - 3) .. "...") or val
    local pad = box_w - 2 - #left_part - #val_display
    if pad < 0 then pad = 0 end

    local inside = ANSI.FG_CYAN .. left_part .. val_color .. val_display .. ANSI.RESET .. string.rep(" ", pad)
    table.insert(lines, "  " .. ANSI.BORDER .. "│" .. inside .. ANSI.BORDER .. "│" .. ANSI.RESET)
  end

  add_detail("Name", cur.title, ANSI.FG_TITLE .. ANSI.BOLD)
  add_detail("Script", cur.file, ANSI.FG_WHITE)
  add_detail("Type", cur.type, ANSI.FG_GREEN)
  add_detail("Backend", cur.backend, ANSI.FG_GRAY)
  table.insert(lines, "  " .. ANSI.BORDER .. "│" .. string.rep(" ", box_w - 2) .. "│" .. ANSI.RESET)

  -- Multiline description
  local first = true
  for line in cur.desc:gmatch("[^\r\n]+") do
    local label = first and "Description" or ""
    first = false
    add_detail(label, line, ANSI.FG_WHITE)
  end

  table.insert(lines, "  " .. ANSI.BORDER .. "│" .. string.rep(" ", box_w - 2) .. "│" .. ANSI.RESET)
  add_detail("Quick Keys", cur.controls, ANSI.FG_YELLOW)

  table.insert(lines, "  " .. ANSI.BORDER .. "│" .. string.rep(" ", box_w - 2) .. "│" .. ANSI.RESET)
  table.insert(lines, "  " .. ANSI.BORDER .. "└──" .. string.rep("─", box_w - 4) .. "┘" .. ANSI.RESET)

  -- 4. Bottom Footer / Key Hints
  while #lines < height - 1 do
    table.insert(lines, "")
  end

  local foot_text = "  [Enter] Launch Program    [↑/↓ or J/K] Navigate    [Q / Esc] Exit"
  table.insert(lines, ANSI.FG_GRAY .. ANSI.DIM .. foot_text .. ANSI.RESET)

  -- Render out
  local frame = ANSI.HOME .. table.concat(lines, "\n")
  C.write(1, frame, #frame)
end

--------------------------------------------------------------------------------
-- Main Loop
--------------------------------------------------------------------------------
local function run_menu(is_test)
  local selected_idx = 1

  if is_test then
    -- Verify manifest and basic render logic
    for _, prog in ipairs(PROGRAMS) do
      assert(prog.file and #prog.file > 0, "Program file must be defined")
      assert(prog.title and #prog.title > 0, "Program title must be defined")
    end
    draw_menu(selected_idx)
    return { ok = true, programs_count = #PROGRAMS }
  end

  local running = true
  while running do
    draw_menu(selected_idx)
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
        print("\n\27[38;2;100;240;130mLaunching " .. prog.title .. "...\27[0m\n")
        -- Run program using LuaJIT
        os.execute("luajit " .. prog.file)
        print("\n\27[38;2;120;210;255m[Press any key to return to menu]\27[0m")
        init_terminal()
        read_key(5000)
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

local ok, err = pcall(function()
  run_menu(is_test)
end)

restore_terminal()

if not ok then
  io.stderr:write("Error: " .. tostring(err) .. "\n")
  os.exit(1)
end

if is_test then
  print("✓ menu.lua verification completed successfully!")
end
