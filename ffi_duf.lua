#!/usr/bin/env luajit
-- ffi_duf.lua  ─  disk usage viewer using LuaJIT FFI
-- Matches duf(1) output: Unicode box-table, progress bar, color coding.
--
-- Usage:
--   luajit ffi_duf.lua

local ffi = require("ffi")
local C   = ffi.C

-- ─────────────────────────────────────────────────────────────────────────────
-- FFI  (x86-64 / aarch64 Linux 64-bit glibc — no _STATVFSBUF_F_UNUSED)
-- ─────────────────────────────────────────────────────────────────────────────
ffi.cdef[[
  struct statvfs {
    unsigned long f_bsize;
    unsigned long f_frsize;
    unsigned long f_blocks;   /* total data blocks (f_frsize units) */
    unsigned long f_bfree;    /* free  blocks                       */
    unsigned long f_bavail;   /* free  blocks for unprivileged user */
    unsigned long f_files;
    unsigned long f_ffree;
    unsigned long f_favail;
    unsigned long f_fsid;
    unsigned long f_flag;
    unsigned long f_namemax;
    unsigned int  f_type;
    int           __f_spare[5];
  };
  int   statvfs(const char *path, struct statvfs *buf);
  char *strerror(int errnum);
  int  *__errno_location(void);
]]

-- ─────────────────────────────────────────────────────────────────────────────
-- ANSI color palette
-- ─────────────────────────────────────────────────────────────────────────────
local A = {
  reset  = "\27[0m",
  bold   = "\27[1m",
  gray   = "\27[90m",   -- dim / box-drawing
  white  = "\27[97m",   -- mount path / device
  yellow = "\27[33m",   -- SIZE / USED
  green  = "\27[92m",   -- AVAIL / low USE%
  orange = "\27[93m",   -- medium USE%
  red    = "\27[91m",   -- high USE%
  cyan   = "\27[36m",   -- section title / TYPE
  hdr    = "\27[1;97m", -- column header (bold white)
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function rpad(s, n) return s .. string.rep(" ", math.max(0, n - #s)) end
local function lpad(s, n) return string.rep(" ", math.max(0, n - #s)) .. s end

-- Human-readable bytes: 0B / 1.2K / 3.4M / 5.6G / …
local function fmt_bytes(b)
  if b == 0 then return "0B" end
  local units = { "B","K","M","G","T","P" }
  local v = b
  for i = 1, #units do
    if v < 1024 or i == #units then
      return i == 1 and string.format("%dB", v)
                     or  string.format("%.1f%s", v, units[i])
    end
    v = v / 1024
  end
end

-- Color for USE% value
local function pct_color(pct)
  if pct >= 90 then return A.red    end
  if pct >= 70 then return A.orange end
  return A.green
end

-- ─────────────────────────────────────────────────────────────────────────────
-- USE% progress bar
--   Visual format: [###.................]  17.3%   (29 chars wide)
--   pct < 0  →  29 spaces (no data)
-- ─────────────────────────────────────────────────────────────────────────────
local BAR_W   = 20                        -- interior bar width in characters
local BAR_VIS = 1 + BAR_W + 1 + 2 + 5    -- [  bar  ]  NN.N%  = 29 visible chars

local function fmt_bar(pct)
  if pct < 0 then
    return string.rep(" ", BAR_VIS)
  end
  local filled = math.max(0, math.min(BAR_W, math.floor(pct / 100 * BAR_W + 0.5)))
  local col     = pct_color(pct)
  local bar_str = col  .. string.rep("#", filled)
               .. A.gray .. string.rep(".", BAR_W - filled)
               .. A.reset
  -- [bar]  N.N%   —  %4.1f pads to 4 chars (e.g. " 0.0" or "17.3")
  return A.gray .. "[" .. A.reset
      .. bar_str
      .. A.gray .. "]" .. A.reset
      .. col .. string.format("  %4.1f%%", pct) .. A.reset
end

-- ─────────────────────────────────────────────────────────────────────────────
-- statvfs wrapper
-- ─────────────────────────────────────────────────────────────────────────────
local _sv = ffi.new("struct statvfs")

local function do_statvfs(path)
  if C.statvfs(path, _sv) ~= 0 then
    return nil, ffi.string(C.strerror(C.__errno_location()[0]))
  end
  local fr    = tonumber(_sv.f_frsize)
  local total = tonumber(_sv.f_blocks) * fr
  local free_ = tonumber(_sv.f_bfree)  * fr
  local avail = tonumber(_sv.f_bavail) * fr
  local used  = total - free_
  -- Show empty USE% when 0 bytes used (e.g. /dev devtmpfs shows all-free)
  local pct   = (total > 0 and used > 0) and (used / total * 100) or -1
  return { total=total, used=used, avail=avail, pct=pct }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Parse /proc/mounts
-- ─────────────────────────────────────────────────────────────────────────────
local function read_mounts()
  local mounts = {}
  local f = assert(io.open("/proc/mounts", "r"), "cannot open /proc/mounts")
  for line in f:lines() do
    local dev, mp, fst = line:match("^(%S+)%s+(%S+)%s+(%S+)")
    if dev then
      -- decode kernel octal escapes (\040 = space, \011 = tab …)
      mp = mp:gsub("\\(%d%d%d)", function(n) return string.char(tonumber(n, 8)) end)
      table.insert(mounts, { device=dev, mountpoint=mp, fstype=fst })
    end
  end
  f:close()
  return mounts
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Filesystem classification  (matches duf's default groups)
-- ─────────────────────────────────────────────────────────────────────────────
-- "local" — real block-device filesystems
local LOCAL_FS = {
  ext2=1, ext3=1, ext4=1,
  btrfs=1, xfs=1, zfs=1, jfs=1, reiserfs=1, nilfs2=1, f2fs=1,
  vfat=1, msdos=1, ntfs=1, exfat=1,
  fuseblk=1, fuse=1,
  hfs=1, hfsplus=1, apfs=1, udf=1,
  nfs=1, nfs4=1, cifs=1, smb3=1,
}

-- "special" — only the user-visible in-memory filesystems duf shows by default
local SPECIAL_FS = { tmpfs=1, devtmpfs=1, ramfs=1 }

-- Everything else (squashfs, proc, sysfs, devpts, cgroup*, bpf, …) is hidden.

-- ─────────────────────────────────────────────────────────────────────────────
-- Unicode box-drawing table renderer
-- Supports multi-line (wrapped) MOUNTED ON cells for long paths.
-- ─────────────────────────────────────────────────────────────────────────────

-- Column definitions: { header, left-align? }
local COLS = {
  { "MOUNTED ON", true  },  -- 1
  { "SIZE",       false },  -- 2
  { "USED",       false },  -- 3
  { "AVAIL",      false },  -- 4
  { "USE%",       false },  -- 5  (special: contains progress bar)
  { "TYPE",       true  },  -- 6
  { "FILESYSTEM", true  },  -- 7
}

-- Map column index → entry field name (nil for MOUNTED ON / USE%)
local FIELD = { nil, "size", "used", "avail", nil, "fstype", "device" }

-- Color for each data column
local COL_COLOR = { A.white, A.yellow, A.yellow, A.green, nil, A.cyan, A.white }

-- Max visual width for MOUNTED ON before wrapping
local MAX_MOUNT_W = 25

local function render(title, entries)
  if #entries == 0 then return end

  -- ── 1. Compute column widths ──────────────────────────────────────────────
  local W = {}
  for i, col in ipairs(COLS) do W[i] = #col[1] end
  W[5] = BAR_VIS  -- USE% always 29 visible chars

  for _, e in ipairs(entries) do
    W[1] = math.min(MAX_MOUNT_W, math.max(W[1], #e.mountpoint))
    W[2] = math.max(W[2], #e.size)
    W[3] = math.max(W[3], #e.used)
    W[4] = math.max(W[4], #e.avail)
    -- W[5] fixed
    W[6] = math.max(W[6], #e.fstype)
    W[7] = math.max(W[7], #e.device)
  end

  -- inner total width (each cell = W[i]+2 padding, separated by │)
  local inner = #W - 1  -- separators
  for _, w in ipairs(W) do inner = inner + w + 2 end

  -- ── 2. Box-drawing helpers ────────────────────────────────────────────────
  local B = {
    h="─", v="│",
    tl="╭", tr="╮", bl="╰", br="╯",
    ml="├", mr="┤", mt="┬", mb="┴", mc="┼",
  }
  local G = A.gray

  local function hline(l, sep, r)
    local segs = {}
    for i, w in ipairs(W) do segs[i] = string.rep(B.h, w+2) end
    return G..l..table.concat(segs, sep)..r..A.reset
  end

  local function vbar() return G..B.v..A.reset end
  local function row_str(cells)
    return vbar()..table.concat(cells, vbar())..vbar()
  end

  -- Build one cell string (padding included, visual width = W[i]+2)
  local function cell(i, text, color)
    local w = W[i]
    local s = COLS[i][2] and rpad(text, w) or lpad(text, w)
    return " "..(color or "")..s..A.reset.." "
  end

  -- USE% header: centered in BAR_VIS
  local function use_hdr_cell()
    local h   = COLS[5][1]   -- "USE%"
    local w   = BAR_VIS
    local lp  = math.floor((w - #h) / 2)
    local rp  = w - #h - lp
    return " "..A.hdr..string.rep(" ",lp)..h..string.rep(" ",rp)..A.reset.." "
  end

  -- ── 3. Print section header ───────────────────────────────────────────────
  print(G..B.tl..string.rep(B.h,inner)..B.tr..A.reset)
  print(vbar().." "..A.cyan..title..string.rep(" ",inner-#title-1)..A.reset..vbar())
  print(hline(B.ml, B.mt, B.mr))

  -- Column header row
  do
    local hcells = {}
    for i = 1, #COLS do
      hcells[i] = i == 5 and use_hdr_cell() or cell(i, COLS[i][1], A.hdr)
    end
    print(row_str(hcells))
  end
  print(hline(B.ml, B.mc, B.mr))

  -- ── 4. Data rows (with path wrapping) ────────────────────────────────────
  for _, e in ipairs(entries) do
    -- Split long mount path into W[1]-wide chunks
    local mp      = e.mountpoint
    local col_w   = W[1]
    local chunks  = {}
    for pos = 1, math.max(1, #mp), col_w do
      table.insert(chunks, mp:sub(pos, pos + col_w - 1))
    end

    for ci, chunk in ipairs(chunks) do
      local dcells = {}
      for i = 1, #COLS do
        if i == 1 then
          -- mount path chunk (every line)
          dcells[i] = " "..A.white..rpad(chunk, W[1])..A.reset.." "
        elseif i == 5 then
          -- progress bar (first line only)
          local bar = ci == 1 and fmt_bar(e.pct) or string.rep(" ", BAR_VIS)
          dcells[i] = " "..bar.." "
        else
          -- other columns (first line only)
          local val = ci == 1 and (e[FIELD[i]] or "") or ""
          dcells[i] = cell(i, val, COL_COLOR[i])
        end
      end
      print(row_str(dcells))
    end
  end

  print(hline(B.bl, B.mb, B.br))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main
-- ─────────────────────────────────────────────────────────────────────────────
local function main()
  local mounts = read_mounts()

  local local_ents   = {}
  local special_ents = {}
  local seen_mp      = {}  -- dedup by exact mountpoint

  for _, m in ipairs(mounts) do
    local mp = m.mountpoint
    if mp == "none" or mp == "" then goto continue end
    if seen_mp[mp]              then goto continue end
    seen_mp[mp] = true

    local stats = do_statvfs(mp)
    if not stats then goto continue end

    local entry = {
      mountpoint = mp,
      device     = m.device,
      fstype     = m.fstype,
      size       = fmt_bytes(stats.total),
      used       = fmt_bytes(stats.used),
      avail      = fmt_bytes(stats.avail),
      pct        = stats.pct,
    }

    if LOCAL_FS[m.fstype] then
      table.insert(local_ents, entry)
    elseif SPECIAL_FS[m.fstype] then
      table.insert(special_ents, entry)
    end
    -- Everything else (squashfs, proc, sysfs, cgroup, …) → hidden

    ::continue::
  end

  local by_mp = function(a, b) return a.mountpoint < b.mountpoint end
  table.sort(local_ents,   by_mp)
  table.sort(special_ents, by_mp)

  local function label(n, kind)
    return n .. " " .. kind .. (n == 1 and "" or "s")
  end

  render(label(#local_ents,   "local device"),   local_ents)
  if #local_ents > 0 and #special_ents > 0 then print() end
  render(label(#special_ents, "special device"), special_ents)
end

main()
