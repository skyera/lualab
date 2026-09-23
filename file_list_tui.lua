#!/usr/bin/env luajit
--- A small dependency-free file browser for Linux terminals.
--- Keys: Up/Down or j/k to move, Enter/right/l to open a directory or file,
--- Backspace/left/h to go up, q or Ctrl-C to quit.

--------------------------------------------------------------------------------
-- Step 1: C FFI and POSIX declarations
-- LuaJIT's FFI gives direct, zero-overhead access to Linux C syscalls and
-- structs without needing external C modules or bindings.
--------------------------------------------------------------------------------
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
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
char *getcwd(char *buf, unsigned long size);
DIR *opendir(const char *name);
struct dirent *readdir(DIR *dirp);
int closedir(DIR *dirp);
int fork(void);
int execvp(const char *file, char *const argv[]);
int waitpid(int pid, int *status, int options);
void _exit(int status);
]]

-- Common POSIX constants
local STDIN, STDOUT = 0, 1
local TCSANOW, TIOCGWINSZ, POLLIN = 0, 0x5413, 0x001

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
  return math.max(1, tonumber(size[0].ws_row)), math.max(1, tonumber(size[0].ws_col))
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

-- Switch into full TUI display (alternate buffer, hide cursor)
local function enable_terminal()
  assert(ffi.C.tcsetattr(STDIN, TCSANOW, raw) == 0, "could not enable raw mode")
  write(esc("?1049h") .. esc("?25l"))
  io.stdout:flush()
end

-- Restore terminal back to normal canonical mode (primary buffer, show cursor)
local function restore_terminal()
  ffi.C.tcsetattr(STDIN, TCSANOW, original)
  write(esc("?25h") .. esc("?1049l"))
  io.stdout:flush()
end

--------------------------------------------------------------------------------
-- Step 5: Screen layout, rendering engine, and dual-pane display
--------------------------------------------------------------------------------
local function main()
  local path = get_cwd()
  local entries, error_message = list_directory(path)
  local selected, offset, dirty, message = 1, 0, true, error_message
  local last_rows, last_cols
  local input = ""
  write(esc("?1049h") .. esc("?25l"))

  -- Reload current directory listing when moving across directories
  local function reload()
    entries, error_message = list_directory(path)
    entries = entries or {}
    selected, offset, message, dirty = 1, 0, error_message, true
  end

  -- Main rendering function: redraws entire screen buffer whenever dirty = true
  local function draw()
    local rows, cols = terminal_size()
    -- Reserve 4 rows: title bar (1), status bar (1), prompt line (1), margin (1)
    local visible = math.max(0, rows - 4)

    -- Keep selected index within valid range
    if selected < 1 then selected = 1 end
    if selected > #entries and #entries > 0 then selected = #entries end

    -- Adjust vertical scroll offset to keep selected row in view
    if selected <= offset then offset = selected - 1 end
    if selected > offset + visible then offset = selected - visible end
    offset = math.max(0, offset)

    -- Determine layout: split into dual panes when terminal width is >= 50 columns
    local split = cols >= 50
    local list_cols = cols
    local preview_cols = 0
    if split then
      list_cols = math.max(20, math.min(36, math.floor(cols * 0.4)))
      preview_cols = cols - list_cols - 1 -- 1 column reserved for divider │
    end

    -- Prepare preview content for currently selected item
    local preview_header = ""
    local preview_lines = {}
    if split and entries[selected] then
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

    -- Reset cursor to top-left and clear display
    write(esc("H") .. esc("2J"))

    -- Render top title bar in inverted colors
    local title = " luals browser  " .. path
    write(esc("7m") .. title:sub(1, cols) .. string.rep(" ", math.max(0, cols - #title)) .. esc("0m\r\n"))

    -- Render main body rows (left file list + optional right preview pane)
    for row = 1, visible do
      local index = offset + row
      local item = entries[index]
      local left_str = ""

      -- Format left list entry
      if item then
        local label = (item.is_dir and "[D] " or "    ") .. clean_name(item.name)
        if #label > list_cols - 2 then
          label = label:sub(1, math.max(0, list_cols - 3)) .. "…"
        end
        local pad = string.rep(" ", math.max(0, list_cols - 2 - #label))
        if index == selected then
          left_str = esc("7m> " .. label .. pad .. esc("0m"))
        else
          left_str = "  " .. label .. pad
        end
      else
        left_str = string.rep(" ", list_cols)
      end

      -- If split view is enabled, append divider and right preview column
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
        write(left_str .. "│" .. right_str)
      else
        write(left_str)
      end
      write(esc("K\r\n"))
    end

    -- Render bottom status bar and keybinding help
    local status = message or ("%d item%s"):format(#entries, #entries == 1 and "" or "s")
    write(esc("7m") .. status:sub(1, cols) .. esc("K") .. esc("0m\r\n"))
    write(" ↑↓/j k move  Enter/right/l open  Backspace/left/h up  q quit" .. esc("K"))
    io.stdout:flush()

    last_rows, last_cols = rows, cols
    dirty = false
  end

  -- Action: enter directory or launch external editor (nvim) for a file
  local function open_selected()
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
      dirty = true
    end
  end

  -- Action: navigate to parent directory
  local function go_parent()
    local next_path = parent(path)
    if next_path ~= path then path = next_path; reload() end
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
    if dirty then draw() end

    -- Wait for input or timeout (timeout allows detecting window size changes)
    local fds = ffi.new("struct pollfd[1]")
    fds[0].fd, fds[0].events = STDIN, POLLIN
    ffi.C.poll(fds, 1, 100)

    if bit.band(fds[0].revents, POLLIN) ~= 0 then
      local buffer = ffi.new("char[64]")
      local count = tonumber(ffi.C.read(STDIN, buffer, 64))
      if count > 0 then input = input .. ffi.string(buffer, count) end

      -- Process accumulated bytes from the input buffer
      while #input > 0 do
        if input:sub(1, 3) == "\27[A" then selected = selected - 1; input = input:sub(4)
        elseif input:sub(1, 3) == "\27[B" then selected = selected + 1; input = input:sub(4)
        elseif input:sub(1, 3) == "\27[C" then open_selected(); input = input:sub(4)
        elseif input:sub(1, 3) == "\27[D" then go_parent(); input = input:sub(4)
        elseif input:sub(1, 1) == "\27" and #input < 3 then
          -- Incomplete ANSI escape sequence; wait for subsequent bytes
          break
        else
          local key = input:sub(1, 1); input = input:sub(2)
          if key == "q" or key == "\3" then return end
          if key == "j" then selected = selected + 1 end
          if key == "k" then selected = selected - 1 end
          if key == "l" or key == "\r" or key == "\n" then open_selected() end
          if key == "h" or key == "\127" then go_parent() end
        end
        selected = math.max(1, math.min(math.max(1, #entries), selected))
        message, dirty = nil, true
      end
    else
      -- Redraw if the terminal was resized during the poll interval
      local rows, cols = terminal_size()
      dirty = rows ~= last_rows or cols ~= last_cols
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
