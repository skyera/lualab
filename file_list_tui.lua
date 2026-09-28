#!/usr/bin/env luajit
--- A small dependency-free file browser for Linux terminals.
--- Keys: Up/Down or j/k to move, Enter/right/l to open a directory or file,
--- Backspace/left/h to go up, ? for help, q or Ctrl-C to quit.

--------------------------------------------------------------------------------
-- Step 1: C FFI and POSIX declarations
-- LuaJIT's FFI gives direct, zero-overhead access to Linux C syscalls and
-- structs without needing external C modules or bindings.
--------------------------------------------------------------------------------
local ffi = require("ffi")
local bit = require("bit")

-- macOS/BSD declare tcflag_t/speed_t as 64-bit and set NCCS to 20, while Linux
-- uses 32-bit and NCCS=32.  Picking the wrong layout shifts every field offset
-- and makes tcgetattr overrun the LuaJIT buffer, so select it at cdef time.
-- On Linux the definition below passes through byte-for-byte unchanged.
local function posix_termios_cdef(def)
    if ffi.os == "OSX" or ffi.os == "BSD" then
        def = def:gsub("unsigned%s+int(%s+[%w_]*tcflag_t)", "unsigned long%1")
        def = def:gsub("unsigned%s+int(%s+[%w_]*speed_t)", "unsigned long%1")
        def = def:gsub("c_cc%[32%]", "c_cc[20]")
    end
    return def
end

ffi.cdef(posix_termios_cdef[[
typedef unsigned int tcflag_t;
typedef unsigned char cc_t;
typedef unsigned int speed_t;

// Terminal control attributes (man termios)
struct termios {
  tcflag_t c_iflag, c_oflag, c_cflag, c_lflag;
  cc_t c_line;
  cc_t c_cc[32];
  speed_t c_ispeed, c_ospeed;
};

// Window sizing struct populated by ioctl TIOCGWINSZ
struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };

// File descriptor polling struct (man 2 poll)
struct pollfd { int fd; short events; short revents; };

// POSIX directory stream types (man 3 opendir, readdir)
typedef struct __dirstream DIR;
struct dirent {
  unsigned long d_ino;
  long d_off;
  unsigned short d_reclen;
  unsigned char d_type;
  char d_name[256];
};

int tcgetattr(int fd, struct termios *termios_p);
int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
int ioctl(int fd, unsigned long request, ...);
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
long read(int fd, void *buf, unsigned long count);
long write(int fd, const void *buf, unsigned long count);
char *getcwd(char *buf, unsigned long size);
DIR *opendir(const char *name);
struct dirent *readdir(DIR *dirp);
int closedir(DIR *dirp);
int fork(void);
int execvp(const char *file, char *const argv[]);
int waitpid(int pid, int *status, int options);
void _exit(int status);
typedef void (*sighandler_t)(int);
sighandler_t signal(int signum, sighandler_t handler);
]])


-- Common POSIX constants
local STDIN, STDOUT = 0, 1
local TCSANOW, TIOCGWINSZ, POLLIN = 0, (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413, 0x001

-- termios flags for disabling canonical mode and echo
local ICANON, ECHO, ISIG, IEXTEN = 0x0002, 0x0008, 0x0001, 0x8000
local IXON, ICRNL, BRKINT, INPCK, ISTRIP = 0x0400, 0x0100, 0x0002, 0x0010, 0x0020
local OPOST, CS8 = 0x0001, 0x0030
local DT_DIR = 4 -- dirent.d_type value indicating a directory

--------------------------------------------------------------------------------
-- Step 2: ANSI escape codes and terminal primitives
-- Escape sequences begin with ESC (\27) followed by command characters:
--   \27[?1049h : Switch to alternate screen buffer (protects caller's terminal)
--   \27[?1049l : Restore original screen buffer
--   \27[?25l   : Hide text cursor to prevent visible flickering during redraw
--   \27[?25h   : Show text cursor again
--   \27[?7l    : Disable line auto-wrap (prevents terminal coordinate drift)
--   \27[?7h    : Re-enable line auto-wrap
--   \27[?2026h : Synchronized update start (atomic frame rendering)
--   \27[?2026l : Synchronized update end
--   \27[H      : Move cursor to home position (row 1, col 1)
--   \27[2J     : Clear the entire display
--   \27[K      : Clear from cursor to the end of the current line
--   \27[7m     : Invert colors (reverse video, used for headers and selection)
--   \27[0m     : Reset text styling back to normal
--------------------------------------------------------------------------------
local function write(s) io.stdout:write(s) end
local function esc(s) return "\27[" .. s end
local function clean_name(s) return s:gsub("[\27\r\n]", "?") end

--------------------------------------------------------------------------------
-- Step 3: File system operations and text preview
--------------------------------------------------------------------------------

-- Retrieve the current working directory path
local function get_cwd()
  local buf = ffi.new("char[?]", 4096)
  assert(ffi.C.getcwd(buf, 4096) ~= nil, "could not get working directory")
  return ffi.string(buf)
end

-- Compute parent path: "/a/b" -> "/a", "/a" -> "/"
local function parent(path)
  if path == "/" then return "/" end
  return path:match("^(.*)/[^/]+$") or "/"
end

-- Read directory entries, sorting directories first, then alphabetically
local function list_directory(path)
  local dir = ffi.C.opendir(path)
  if dir == nil then return nil, "cannot open " .. path end
  local entries = {}
  while true do
    local entry = ffi.C.readdir(dir)
    if entry == nil then break end
    local name = ffi.string(entry.d_name)
    if name ~= "." and name ~= ".." then
      entries[#entries + 1] = { name = name, is_dir = entry.d_type == DT_DIR }
    end
  end
  ffi.C.closedir(dir)
  table.sort(entries, function(a, b)
    if a.is_dir ~= b.is_dir then return a.is_dir end
    return a.name:lower() < b.name:lower()
  end)
  return entries
end

-- Query the terminal dimensions (rows and columns) dynamically
local function terminal_size()
  local size = ffi.new("struct winsize[1]")
  if ffi.C.ioctl(STDOUT, TIOCGWINSZ, size) ~= 0 then return 24, 80 end
  local r = tonumber(size[0].ws_row)
  local c = tonumber(size[0].ws_col)
  if r <= 0 or c <= 0 then return 24, 80 end
  return r, c
end

-- Safely inspect and read text file preview lines (filters out binary files)
local function read_preview(filepath, max_lines, max_bytes)
  local f = io.open(filepath, "rb")
  if not f then return nil, "cannot read file" end
  local chunk = f:read(max_bytes or 16384)
  f:close()
  if not chunk or #chunk == 0 then return { "(empty file)" } end
  -- If chunk contains null byte \0, treat it as a binary file to avoid screen corruption
  if chunk:find("%z") then return nil, "(binary file)" end

  local lines = {}
  local pos = 1
  while pos <= #chunk and #lines < max_lines do
    local nl = chunk:find("\n", pos, true)
    local line
    if nl then
      line = chunk:sub(pos, nl - 1)
      pos = nl + 1
    else
      line = chunk:sub(pos)
      pos = #chunk + 1
    end
    line = line:gsub("\r$", ""):gsub("\t", "    ")
    lines[#lines + 1] = clean_name(line)
  end
  return lines
end

--------------------------------------------------------------------------------
-- Step 4: Terminal raw mode configuration
-- By default, Unix terminals run in canonical mode: input is buffered line-by-line
-- until Enter is pressed, and characters are echoed back to the screen.
-- In raw mode:
--   - ICANON is disabled: keystrokes arrive immediately as they are pressed.
--   - ECHO is disabled: the program explicitly decides what to draw.
--   - VMIN=0, VTIME=0: non-blocking reads combined with poll().
--------------------------------------------------------------------------------
local original = ffi.new("struct termios[1]")
assert(ffi.C.tcgetattr(STDIN, original) == 0, "This program must run in a terminal.")
local raw = ffi.new("struct termios[1]", original[0])
raw[0].c_lflag = bit.band(raw[0].c_lflag, bit.bnot(bit.bor(ICANON, ECHO, ISIG, IEXTEN)))
raw[0].c_iflag = bit.band(raw[0].c_iflag, bit.bnot(bit.bor(IXON, ICRNL, BRKINT, INPCK, ISTRIP)))
raw[0].c_oflag = bit.band(raw[0].c_oflag, bit.bnot(OPOST))
raw[0].c_cflag = bit.bor(raw[0].c_cflag, CS8)
raw[0].c_cc[6], raw[0].c_cc[5] = 0, 0 -- VMIN, VTIME on Linux
assert(ffi.C.tcsetattr(STDIN, TCSANOW, raw) == 0, "could not enable raw mode")

-- Switch into full TUI display (alternate buffer, hide cursor, disable auto-wrap)
local function enable_terminal()
  assert(ffi.C.tcsetattr(STDIN, TCSANOW, raw) == 0, "could not enable raw mode")
  write(esc("?1049h") .. esc("?25l") .. esc("?7l"))
  io.stdout:flush()
end

-- Restore terminal back to normal canonical mode (primary buffer, show cursor, re-enable auto-wrap)
local function restore_terminal()
  ffi.C.tcsetattr(STDIN, TCSANOW, original)
  write(esc("?7h") .. esc("?25h") .. esc("?1049l"))
  io.stdout:flush()
end

-- Signal trap to guarantee terminal restoration on SIGINT or SIGTERM
local function on_sig(sig)
  ffi.C.tcsetattr(STDIN, TCSANOW, original)
  local reset_seq = "\27[?7h\27[?25h\27[?1049l"
  ffi.C.write(STDOUT, reset_seq, #reset_seq)
  ffi.C._exit(128 + sig)
end
local sig_cb = ffi.cast("sighandler_t", on_sig)
ffi.C.signal(2, sig_cb)  -- SIGINT
ffi.C.signal(15, sig_cb) -- SIGTERM

--------------------------------------------------------------------------------
-- Step 5: Screen layout, rendering engine, and dual-pane display
--------------------------------------------------------------------------------
local function main()
  -- Forward declarations for rendering and navigation functions
  local render_full_screen
  local render_selection_differential
  local reload
  local open_selected
  local go_parent

  local path = get_cwd()
  local entries, error_message = list_directory(path)
  local selected, offset, message = 1, 0, error_message
  local show_help = false
  local prev_selected, prev_offset = selected, offset
  local last_rows, last_cols
  local input = ""

  enable_terminal()

  -- Compute current layout boundaries and invariants
  local function compute_layout()
    local raw_rows, raw_cols = terminal_size()
    -- Clamp layout width to raw_cols - 1 to prevent auto-wrap shifting cursor
    local cols = math.max(10, raw_cols - 1)
    local rows = raw_rows
    -- Reserve 4 rows: title bar (1), status bar (1), help line (1), margin (1)
    local visible = math.max(0, rows - 4)

    -- Strict Viewport Bounds & Invariants
    if #entries == 0 then
      selected = 1
      offset = 0
    else
      if selected < 1 then selected = 1 end
      if selected > #entries then selected = #entries end
      if selected <= offset then offset = selected - 1 end
      if selected > offset + visible then offset = selected - visible end
      offset = math.max(0, offset)
    end

    local split = cols >= 50
    local list_cols = cols
    local preview_cols = 0
    if split then
      list_cols = math.max(20, math.min(36, math.floor(cols * 0.4)))
      preview_cols = cols - list_cols - 1 -- 1 column reserved for divider │
    end

    return rows, cols, visible, split, list_cols, preview_cols
  end

  local function format_left_entry(item, is_selected, list_cols)
    if not item then
      return string.rep(" ", list_cols)
    end
    local label = (item.is_dir and "[D] " or "    ") .. clean_name(item.name)
    if #label > list_cols - 2 then
      label = label:sub(1, math.max(0, list_cols - 3)) .. "…"
    end
    local pad = string.rep(" ", math.max(0, list_cols - 2 - #label))
    if is_selected then
      return esc("7m> " .. label .. pad .. esc("0m"))
    else
      return "  " .. label .. pad
    end
  end

  local function get_preview(visible)
    local preview_header = ""
    local preview_lines = {}
    if entries[selected] then
      local item = entries[selected]
      local item_path = path == "/" and "/" .. item.name or path .. "/" .. item.name
      if item.is_dir then
        preview_header = " [Directory] " .. item.name
        preview_lines = { "  (directory)" }
      else
        local lines, err = read_preview(item_path, visible - 1)
        if lines then
          preview_header = " Preview: " .. item.name
          preview_lines = lines
        else
          preview_header = " File: " .. item.name
          preview_lines = { "  " .. (err or "cannot preview") }
        end
      end
    end
    return preview_header, preview_lines
  end

  -- Full screen redraw with atomic synchronized update
  -- full_clear is ONLY true for initial start, window resize, return from editor, or reload
  render_full_screen = function(full_clear)
    local rows, cols, visible, split, list_cols, preview_cols = compute_layout()
    local preview_header, preview_lines = "", {}
    if split and not show_help then
      preview_header, preview_lines = get_preview(visible)
    end

    -- Atomic Synchronized Frame Emission: \27[?2026h ... \27[?2026l
    local buf = { esc("?2026h") }

    if full_clear then
      buf[#buf + 1] = esc("2J")
    end
    buf[#buf + 1] = esc("H")

    if show_help then
      -- Top title bar for help screen
      local title = " luals browser  Help — Keyboard Shortcuts"
      buf[#buf + 1] = esc("7m") .. title:sub(1, cols) .. string.rep(" ", math.max(0, cols - #title)) .. esc("0m\r\n")

      local help_lines = {
        "",
        "  Navigation",
        "    ↑ / k               Move selection up",
        "    ↓ / j               Move selection down",
        "    ← / h / Backspace   Navigate to parent directory",
        "",
        "  Actions",
        "    → / l / Enter       Open directory or edit file in $EDITOR (nvim)",
        "    ?                   Toggle this help screen",
        "    q / Ctrl-C          Quit browser",
        "",
        "  Display & Layout",
        "    Left pane           File & directory listing ([D] = directory)",
        "    Right pane          File preview (on terminals ≥ 50 columns)",
      }

      for row = 1, visible do
        local line = help_lines[row] or ""
        buf[#buf + 1] = line:sub(1, cols) .. string.rep(" ", math.max(0, cols - #line)) .. esc("K\r\n")
      end

      local status = " Help View  (press ?, q, or Esc to return)"
      buf[#buf + 1] = esc("7m") .. status:sub(1, cols) .. string.rep(" ", math.max(0, cols - #status)) .. esc("0m\r\n")
      local help = " Press ?, q, or Esc to close help"
      buf[#buf + 1] = help:sub(1, cols) .. esc("K")
    else
      -- Render top title bar in inverted colors
      local title = " luals browser  " .. path
      buf[#buf + 1] = esc("7m") .. title:sub(1, cols) .. string.rep(" ", math.max(0, cols - #title)) .. esc("0m\r\n")

      -- Render main body rows (left file list + optional right preview pane)
      for row = 1, visible do
        local index = offset + row
        local item = entries[index]
        local left_str = format_left_entry(item, index == selected, list_cols)

        if split then
          local right_str = ""
          if row == 1 then
            local hdr = preview_header:sub(1, preview_cols)
            right_str = esc("7m") .. hdr .. string.rep(" ", math.max(0, preview_cols - #hdr)) .. esc("0m")
          else
            local pline = preview_lines[row - 1]
            if pline then
              pline = pline:sub(1, preview_cols)
              right_str = pline .. string.rep(" ", math.max(0, preview_cols - #pline))
            else
              right_str = string.rep(" ", preview_cols)
            end
          end
          buf[#buf + 1] = left_str .. "│" .. right_str
        else
          buf[#buf + 1] = left_str
        end
        buf[#buf + 1] = esc("K\r\n")
      end

      -- Render bottom status bar and keybinding help
      local status = message or ("%d item%s"):format(#entries, #entries == 1 and "" or "s")
      buf[#buf + 1] = esc("7m") .. status:sub(1, cols) .. string.rep(" ", math.max(0, cols - #status)) .. esc("0m\r\n")
      local help = " ↑↓/j k move  Enter/l open  h/Back up  ? help  q quit"
      buf[#buf + 1] = help:sub(1, cols) .. esc("K")
    end

    buf[#buf + 1] = esc("?2026l")
    io.stdout:write(table.concat(buf))
    io.stdout:flush()

    last_rows, last_cols = rows, cols
    prev_selected, prev_offset = selected, offset
  end

  -- Differential update on local movement: updates only changed rows
  render_selection_differential = function(old_sel, new_sel)
    if show_help then
      render_full_screen(false)
      return
    end
    local rows, cols, visible, split, list_cols, preview_cols = compute_layout()
    -- If viewport scrolled or in split pane mode (where preview pane reflects current file),
    -- fall back to atomic synchronized full screen refresh (without full clear \27[2J).
    if offset ~= prev_offset or split then
      render_full_screen(false)
      return
    end

    -- Single-pane differential update: only overwrite changed rows
    local buf = { esc("?2026h") }

    local old_row = 1 + (old_sel - offset)
    local new_row = 1 + (new_sel - offset)

    if old_row >= 2 and old_row <= visible + 1 then
      buf[#buf + 1] = esc(string.format("%d;1H", old_row))
      buf[#buf + 1] = format_left_entry(entries[old_sel], false, list_cols) .. esc("K")
    end

    if new_row >= 2 and new_row <= visible + 1 then
      buf[#buf + 1] = esc(string.format("%d;1H", new_row))
      buf[#buf + 1] = format_left_entry(entries[new_sel], true, list_cols) .. esc("K")
    end

    -- Update status bar
    local status_row = visible + 2
    buf[#buf + 1] = esc(string.format("%d;1H", status_row))
    local status = message or ("%d item%s"):format(#entries, #entries == 1 and "" or "s")
    buf[#buf + 1] = esc("7m") .. status:sub(1, cols) .. string.rep(" ", math.max(0, cols - #status)) .. esc("0m") .. esc("K")

    buf[#buf + 1] = esc("?2026l")
    io.stdout:write(table.concat(buf))
    io.stdout:flush()

    prev_selected, prev_offset = selected, offset
  end

  -- Reload current directory listing when moving across directories
  reload = function()
    entries, error_message = list_directory(path)
    entries = entries or {}
    selected, offset, message = 1, 0, error_message
    prev_selected, prev_offset = 1, 0
    show_help = false
    render_full_screen(true)
  end

  -- Action: enter directory or launch external editor (nvim) for a file
  open_selected = function()
    local item = entries[selected]
    if item and item.is_dir then
      path = path == "/" and "/" .. item.name or path .. "/" .. item.name
      reload()
    elseif item then
      local filename = path == "/" and "/" .. item.name or path .. "/" .. item.name
      -- Temporarily restore terminal so nvim can take over standard input and output
      restore_terminal()
      local pid = ffi.C.fork()
      if pid == 0 then
        local editor = ffi.new("char[5]", "nvim")
        local target = ffi.new("char[?]", #filename + 1)
        ffi.copy(target, filename)
        local argv = ffi.new("char *[3]", { editor, target, nil })
        ffi.C.execvp(editor, argv)
        ffi.C._exit(127)
      end
      local status = ffi.new("int[1]")
      ffi.C.waitpid(pid, status, 0)
      -- Re-enter raw mode and restore TUI screen after editor exits
      enable_terminal()
      message = bit.band(status[0], 0x7f) == 0 and ("closed nvim: " .. item.name) or ("nvim failed: " .. item.name)
      render_full_screen(true)
    end
  end

  -- Action: navigate to parent directory
  go_parent = function()
    local next_path = parent(path)
    if next_path ~= path then
      path = next_path
      reload()
    end
  end

  ------------------------------------------------------------------------------
  -- Step 6: Event loop and escape sequence parser
  -- We poll stdin with a 100ms timeout.
  -- Key sequences:
  --   \27[A = Up Arrow
  --   \27[B = Down Arrow
  --   \27[C = Right Arrow
  --   \27[D = Left Arrow
  --   \127  = Backspace
  --   \3    = Ctrl-C
  ------------------------------------------------------------------------------
  reload()
  while true do
    -- Wait for input or timeout (timeout allows detecting window size changes)
    local fds = ffi.new("struct pollfd[1]")
    fds[0].fd, fds[0].events = STDIN, POLLIN
    ffi.C.poll(fds, 1, 100)

    if bit.band(fds[0].revents, POLLIN) ~= 0 then
      local buffer = ffi.new("char[64]")
      local count = tonumber(ffi.C.read(STDIN, buffer, 64))
      if count > 0 then input = input .. ffi.string(buffer, count) end

      local old_sel = selected
      local old_off = offset
      local moved = false

      -- Process accumulated bytes from the input buffer
      while #input > 0 do
        if input:sub(1, 3) == "\27[A" then
          input = input:sub(4)
          if not show_help then
            selected = selected - 1
            moved = true
          end
        elseif input:sub(1, 3) == "\27[B" then
          input = input:sub(4)
          if not show_help then
            selected = selected + 1
            moved = true
          end
        elseif input:sub(1, 3) == "\27[C" then
          input = input:sub(4)
          if show_help then
            show_help = false
            render_full_screen(false)
          else
            if moved then
              selected = math.max(1, math.min(math.max(1, #entries), selected))
              compute_layout()
              moved = false
            end
            open_selected()
            old_sel, old_off = selected, offset
          end
        elseif input:sub(1, 3) == "\27[D" then
          input = input:sub(4)
          if show_help then
            show_help = false
            render_full_screen(false)
          else
            if moved then
              selected = math.max(1, math.min(math.max(1, #entries), selected))
              compute_layout()
              moved = false
            end
            go_parent()
            old_sel, old_off = selected, offset
          end
        elseif input:sub(1, 1) == "\27" and #input < 3 then
          -- Incomplete ANSI escape sequence; wait for subsequent bytes
          break
        else
          local key = input:sub(1, 1)
          input = input:sub(2)
          if key == "\3" then return end
          if show_help then
            if key == "?" or key == "q" or key == "\27" or key == "\r" or key == "\n" or key == " " then
              show_help = false
              render_full_screen(false)
            end
          else
            if key == "q" then return end
            if key == "?" then
              show_help = true
              render_full_screen(false)
            elseif key == "j" then
              selected = selected + 1
              moved = true
            elseif key == "k" then
              selected = selected - 1
              moved = true
            elseif key == "l" or key == "\r" or key == "\n" then
              if moved then
                selected = math.max(1, math.min(math.max(1, #entries), selected))
                compute_layout()
                moved = false
              end
              open_selected()
              old_sel, old_off = selected, offset
            elseif key == "h" or key == "\127" then
              if moved then
                selected = math.max(1, math.min(math.max(1, #entries), selected))
                compute_layout()
                moved = false
              end
              go_parent()
              old_sel, old_off = selected, offset
            end
          end
        end
      end

      -- Drain burst keystrokes cleanly before rendering
      if moved then
        selected = math.max(1, math.min(math.max(1, #entries), selected))
        message = nil
        if selected ~= old_sel then
          compute_layout()
          if offset ~= old_off then
            render_full_screen(false)
          else
            render_selection_differential(old_sel, selected)
          end
        end
      end
    else
      -- Redraw if the terminal was resized during the poll interval
      local raw_rows, raw_cols = terminal_size()
      local cols = math.max(10, raw_cols - 1)
      if raw_rows ~= last_rows or cols ~= last_cols then
        render_full_screen(true)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Step 7: Safe execution wrapper
-- Always ensure restore_terminal() executes even if a Lua runtime error occurs.
-- Without this, the user's terminal would remain in raw mode and invisible cursor!
--------------------------------------------------------------------------------
local ok, err = xpcall(main, debug.traceback)
restore_terminal()
if not ok then io.stderr:write(err .. "\n"); os.exit(1) end
