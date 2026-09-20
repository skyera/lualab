-- ffi_duf_shared.lua
-- Shared formatting, classification, and table rendering for ffi_duf.
-- Platform-specific data collection is handled by backend modules.
-- Each backend must expose:  get_mounts() → { mountpoint, device, fstype, total, used, avail }[]

local M = {}

-- ─── ANSI color palette ───────────────────────────────────────────────────
M.A = {
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
local A = M.A

-- ─── String helpers ───────────────────────────────────────────────────────
local function rpad(s, n) return s .. string.rep(" ", math.max(0, n - #s)) end
local function lpad(s, n) return string.rep(" ", math.max(0, n - #s)) .. s end

-- ─── Human-readable bytes ─────────────────────────────────────────────────
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

-- ─── USE% progress bar ────────────────────────────────────────────────────
-- Visual format (29 chars fixed):  [###.................]  17.3%
local BAR_W   = 20                      -- interior bar width in characters
local BAR_VIS = 1 + BAR_W + 1 + 2 + 5  -- 29 visible chars total

local function pct_color(pct)
  if pct >= 90 then return A.red    end
  if pct >= 70 then return A.orange end
  return A.green
end

local function fmt_bar(pct)
  if pct < 0 then return string.rep(" ", BAR_VIS) end
  local filled = math.max(0, math.min(BAR_W, math.floor(pct / 100 * BAR_W + 0.5)))
  local col = pct_color(pct)
  local bar = col  .. string.rep("#", filled)
           .. A.gray .. string.rep(".", BAR_W - filled) .. A.reset
  return A.gray .. "[" .. A.reset .. bar .. A.gray .. "]" .. A.reset
      .. col .. string.format("  %4.1f%%", pct) .. A.reset
end

-- ─── Filesystem classification ────────────────────────────────────────────

-- "local" group: real block-device filesystems (Linux + macOS + Windows)
local LOCAL_FS = {
  -- Linux common
  ext2=1, ext3=1, ext4=1,
  btrfs=1, xfs=1, zfs=1, jfs=1, reiserfs=1, nilfs2=1, f2fs=1,
  -- FAT / optical / Windows
  vfat=1, msdos=1, fat32=1, exfat=1, ntfs=1, refs=1, cdfs=1,
  -- Optical / generic
  udf=1, iso9660=1,
  -- macOS
  hfs=1, hfsplus=1, apfs=1,
  -- FUSE
  fuse=1, fuseblk=1,
  -- Network
  nfs=1, nfs4=1, cifs=1, smb3=1, smbfs=1,
}

-- "special" group: in-memory / virtual filesystems shown by default
local SPECIAL_FS = {
  tmpfs=1, devtmpfs=1, ramfs=1,   -- Linux
  devfs=1,                        -- macOS /dev
}

-- Everything else (squashfs, proc, sysfs, cgroup*, devpts, bpf, …) is hidden.

M.LOCAL_FS   = LOCAL_FS
M.SPECIAL_FS = SPECIAL_FS

-- ─── Table column layout ──────────────────────────────────────────────────
-- { header, left-align? }
local COLS = {
  { "MOUNTED ON", true  },  -- 1
  { "SIZE",       false },  -- 2
  { "USED",       false },  -- 3
  { "AVAIL",      false },  -- 4
  { "USE%",       false },  -- 5  (progress bar — special)
  { "TYPE",       true  },  -- 6
  { "FILESYSTEM", true  },  -- 7
}

local FIELD     = { nil, "size", "used", "avail", nil, "fstype", "device" }
local COL_COLOR = { A.white, A.yellow, A.yellow, A.green, nil, A.cyan, A.white }
local MAX_MOUNT_W = 25  -- cap MOUNTED ON width; longer paths wrap

-- ─── Section renderer ─────────────────────────────────────────────────────
local function render(title, entries)
  if #entries == 0 then return end

  -- compute column widths
  local W = {}
  for i, col in ipairs(COLS) do W[i] = #col[1] end
  W[5] = BAR_VIS  -- USE% column always 29 chars wide

  for _, e in ipairs(entries) do
    W[1] = math.min(MAX_MOUNT_W, math.max(W[1], #e.mountpoint))
    W[2] = math.max(W[2], #e.size)
    W[3] = math.max(W[3], #e.used)
    W[4] = math.max(W[4], #e.avail)
    -- W[5] is fixed
    W[6] = math.max(W[6], #e.fstype)
    W[7] = math.max(W[7], #e.device)
  end

  -- total inner width (cells + separators)
  local inner = #W - 1
  for _, w in ipairs(W) do inner = inner + w + 2 end

  -- box-drawing characters
  local B = {
    h="─", v="│", tl="╭", tr="╮", bl="╰", br="╯",
    ml="├", mr="┤", mt="┬", mb="┴", mc="┼",
  }
  local G = A.gray

  local function hline(l, sep, r)
    local segs = {}
    for i, w in ipairs(W) do segs[i] = string.rep(B.h, w+2) end
    return G..l..table.concat(segs, sep)..r..A.reset
  end

  local function vbar()     return G..B.v..A.reset end
  local function row_str(c) return vbar()..table.concat(c, vbar())..vbar() end

  local function cell(i, text, color)
    local w = W[i]
    local s = COLS[i][2] and rpad(text, w) or lpad(text, w)
    return " "..(color or "")..s..A.reset.." "
  end

  -- "USE%" header centered inside BAR_VIS
  local function use_hdr_cell()
    local h  = COLS[5][1]
    local w  = BAR_VIS
    local lp = math.floor((w - #h) / 2)
    local rp = w - #h - lp
    return " "..A.hdr..string.rep(" ", lp)..h..string.rep(" ", rp)..A.reset.." "
  end

  -- title row
  print(G..B.tl..string.rep(B.h, inner)..B.tr..A.reset)
  print(vbar().." "..A.cyan..title..string.rep(" ", inner - #title - 1)..A.reset..vbar())
  print(hline(B.ml, B.mt, B.mr))

  -- header row
  do
    local hcells = {}
    for i = 1, #COLS do
      hcells[i] = (i == 5) and use_hdr_cell() or cell(i, COLS[i][1], A.hdr)
    end
    print(row_str(hcells))
  end
  print(hline(B.ml, B.mc, B.mr))

  -- data rows (with mount-path wrapping)
  for _, e in ipairs(entries) do
    local mp     = e.mountpoint
    local col_w  = W[1]
    local chunks = {}
    for pos = 1, math.max(1, #mp), col_w do
      table.insert(chunks, mp:sub(pos, pos + col_w - 1))
    end

    for ci, chunk in ipairs(chunks) do
      local dcells = {}
      for i = 1, #COLS do
        if i == 1 then
          dcells[i] = " "..A.white..rpad(chunk, W[1])..A.reset.." "
        elseif i == 5 then
          local bar = (ci == 1) and fmt_bar(e.pct) or string.rep(" ", BAR_VIS)
          dcells[i] = " "..bar.." "
        else
          local val = (ci == 1) and (e[FIELD[i]] or "") or ""
          dcells[i] = cell(i, val, COL_COLOR[i])
        end
      end
      print(row_str(dcells))
    end
  end

  print(hline(B.bl, B.mb, B.br))
end

-- ─── Public: classify + format + render ──────────────────────────────────
-- backend  a module with get_mounts() → raw entry list
function M.run(backend)
  local raw = backend.get_mounts()

  local local_ents   = {}
  local special_ents = {}

  for _, m in ipairs(raw) do
    -- USE% is empty (-1) when used == 0 bytes (matches duf behaviour)
    local pct = (m.total > 0 and m.used > 0)
                and (m.used / m.total * 100) or -1
    local entry = {
      mountpoint = m.mountpoint,
      device     = m.device,
      fstype     = m.fstype,
      size       = fmt_bytes(m.total),
      used       = fmt_bytes(m.used),
      avail      = fmt_bytes(m.avail),
      pct        = pct,
    }
    if LOCAL_FS[m.fstype] then
      table.insert(local_ents, entry)
    elseif SPECIAL_FS[m.fstype] then
      table.insert(special_ents, entry)
    end
  end

  local by_mp = function(a, b) return a.mountpoint < b.mountpoint end
  table.sort(local_ents,   by_mp)
  table.sort(special_ents, by_mp)

  local function label(n, kind)
    return n.." "..kind..(n == 1 and "" or "s")
  end

  render(label(#local_ents,   "local device"),   local_ents)
  if #local_ents > 0 and #special_ents > 0 then print() end
  render(label(#special_ents, "special device"), special_ents)
end

return M
