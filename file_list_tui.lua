#!/usr/bin/env luajit
--- A small dependency-free file browser for Linux terminals.
--- Keys: Up/Down or j/k, Enter/right to open a directory, Backspace/left/h
--- to go up, q or Ctrl-C to quit.

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
typedef unsigned int tcflag_t;
typedef unsigned char cc_t;
typedef unsigned int speed_t;
struct termios {
  tcflag_t c_iflag, c_oflag, c_cflag, c_lflag;
  cc_t c_line;
  cc_t c_cc[32];
  speed_t c_ispeed, c_ospeed;
};
struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
struct pollfd { int fd; short events; short revents; };
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

local STDIN, STDOUT = 0, 1
local TCSANOW, TIOCGWINSZ, POLLIN = 0, 0x5413, 0x001
local ICANON, ECHO, ISIG, IEXTEN = 0x0002, 0x0008, 0x0001, 0x8000
local IXON, ICRNL, BRKINT, INPCK, ISTRIP = 0x0400, 0x0100, 0x0002, 0x0010, 0x0020
local OPOST, CS8 = 0x0001, 0x0030
local DT_DIR = 4

local function write(s) io.stdout:write(s) end
local function esc(s) return "\27[" .. s end
local function clean_name(s) return s:gsub("[\27\r\n]", "?") end

local function get_cwd()
  local buf = ffi.new("char[?]", 4096)
  assert(ffi.C.getcwd(buf, 4096) ~= nil, "could not get working directory")
  return ffi.string(buf)
end

local function parent(path)
  if path == "/" then return "/" end
  return path:match("^(.*)/[^/]+$") or "/"
end

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

local function terminal_size()
  local size = ffi.new("struct winsize[1]")
  if ffi.C.ioctl(STDOUT, TIOCGWINSZ, size) ~= 0 then return 24, 80 end
  return math.max(1, tonumber(size[0].ws_row)), math.max(1, tonumber(size[0].ws_col))
end

local function read_preview(filepath, max_lines, max_bytes)
  local f = io.open(filepath, "rb")
  if not f then return nil, "cannot read file" end
  local chunk = f:read(max_bytes or 16384)
  f:close()
  if not chunk or #chunk == 0 then return { "(empty file)" } end
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

local original = ffi.new("struct termios[1]")
assert(ffi.C.tcgetattr(STDIN, original) == 0, "This program must run in a terminal.")
local raw = ffi.new("struct termios[1]", original[0])
raw[0].c_lflag = bit.band(raw[0].c_lflag, bit.bnot(bit.bor(ICANON, ECHO, ISIG, IEXTEN)))
raw[0].c_iflag = bit.band(raw[0].c_iflag, bit.bnot(bit.bor(IXON, ICRNL, BRKINT, INPCK, ISTRIP)))
raw[0].c_oflag = bit.band(raw[0].c_oflag, bit.bnot(OPOST))
raw[0].c_cflag = bit.bor(raw[0].c_cflag, CS8)
raw[0].c_cc[6], raw[0].c_cc[5] = 0, 0 -- VMIN, VTIME on Linux
assert(ffi.C.tcsetattr(STDIN, TCSANOW, raw) == 0, "could not enable raw mode")

local function enable_terminal()
  assert(ffi.C.tcsetattr(STDIN, TCSANOW, raw) == 0, "could not enable raw mode")
  write(esc("?1049h") .. esc("?25l"))
  io.stdout:flush()
end

local function restore_terminal()
  ffi.C.tcsetattr(STDIN, TCSANOW, original)
  write(esc("?25h") .. esc("?1049l"))
  io.stdout:flush()
end

local function main()
  local path = get_cwd()
  local entries, error_message = list_directory(path)
  local selected, offset, dirty, message = 1, 0, true, error_message
  local last_rows, last_cols
  local input = ""
  write(esc("?1049h") .. esc("?25l"))

  local function reload()
    entries, error_message = list_directory(path)
    entries = entries or {}
    selected, offset, message, dirty = 1, 0, error_message, true
  end

  local function draw()
    local rows, cols = terminal_size()
    local visible = math.max(0, rows - 4)
    if selected < 1 then selected = 1 end
    if selected > #entries and #entries > 0 then selected = #entries end
    if selected <= offset then offset = selected - 1 end
    if selected > offset + visible then offset = selected - visible end
    offset = math.max(0, offset)

    -- Determine layout (split view if cols >= 50)
    local split = cols >= 50
    local list_cols = cols
    local preview_cols = 0
    if split then
      list_cols = math.max(20, math.min(36, math.floor(cols * 0.4)))
      preview_cols = cols - list_cols - 1 -- 1 column for separator
    end

    -- Prepare preview for selected item if split view
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

    write(esc("H") .. esc("2J"))
    local title = " luals browser  " .. path
    write(esc("7m") .. title:sub(1, cols) .. string.rep(" ", math.max(0, cols - #title)) .. esc("0m\r\n"))
    for row = 1, visible do
      local index = offset + row
      local item = entries[index]
      local left_str = ""
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
    local status = message or ("%d item%s"):format(#entries, #entries == 1 and "" or "s")
    write(esc("7m") .. status:sub(1, cols) .. esc("K") .. esc("0m\r\n"))
    write(" ↑↓/j k move  Enter/right/l open  Backspace/left/h up  q quit" .. esc("K"))
    io.stdout:flush()
    last_rows, last_cols = rows, cols
    dirty = false
  end

  local function open_selected()
    local item = entries[selected]
    if item and item.is_dir then
      path = path == "/" and "/" .. item.name or path .. "/" .. item.name
      reload()
    elseif item then
      local filename = path == "/" and "/" .. item.name or path .. "/" .. item.name
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
      enable_terminal()
      message = bit.band(status[0], 0x7f) == 0 and ("closed nvim: " .. item.name) or ("nvim failed: " .. item.name)
      dirty = true
    end
  end

  local function go_parent()
    local next_path = parent(path)
    if next_path ~= path then path = next_path; reload() end
  end

  reload()
  while true do
    if dirty then draw() end
    local fds = ffi.new("struct pollfd[1]")
    fds[0].fd, fds[0].events = STDIN, POLLIN
    ffi.C.poll(fds, 1, 100) -- periodically redraw to notice a resize
    if bit.band(fds[0].revents, POLLIN) ~= 0 then
      local buffer = ffi.new("char[64]")
      local count = tonumber(ffi.C.read(STDIN, buffer, 64))
      if count > 0 then input = input .. ffi.string(buffer, count) end
      while #input > 0 do
        if input:sub(1, 3) == "\27[A" then selected = selected - 1; input = input:sub(4)
        elseif input:sub(1, 3) == "\27[B" then selected = selected + 1; input = input:sub(4)
        elseif input:sub(1, 3) == "\27[C" then open_selected(); input = input:sub(4)
        elseif input:sub(1, 3) == "\27[D" then go_parent(); input = input:sub(4)
        elseif input:sub(1, 1) == "\27" and #input < 3 then break
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
      local rows, cols = terminal_size()
      dirty = rows ~= last_rows or cols ~= last_cols
    end
  end
end

local ok, err = xpcall(main, debug.traceback)
restore_terminal()
if not ok then io.stderr:write(err .. "\n"); os.exit(1) end
