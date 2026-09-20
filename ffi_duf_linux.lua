-- ffi_duf_linux.lua
-- Linux backend for ffi_duf.
-- Reads mount list from /proc/mounts and queries disk stats via statvfs(3).
--
-- Returned entry shape:
--   { mountpoint, device, fstype, total, used, avail }   (all sizes in bytes)

local ffi = require("ffi")
local C   = ffi.C

-- ─── FFI declarations (64-bit Linux glibc / x86-64 / aarch64) ────────────
-- _STATVFSBUF_F_UNUSED is NOT defined on 64-bit Linux, so no __f_unused field.
ffi.cdef[[
  struct statvfs {
    unsigned long f_bsize;    /* preferred block size               */
    unsigned long f_frsize;   /* fundamental block size             */
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

local _sv = ffi.new("struct statvfs")

local function do_statvfs(path)
  if C.statvfs(path, _sv) ~= 0 then return nil end
  local fr    = tonumber(_sv.f_frsize)
  local total = tonumber(_sv.f_blocks) * fr
  local free_ = tonumber(_sv.f_bfree)  * fr
  local avail = tonumber(_sv.f_bavail) * fr
  return { total = total, used = total - free_, avail = avail }
end

-- ─── /proc/mounts parser ──────────────────────────────────────────────────
local function read_mounts()
  local mounts = {}
  local f = assert(io.open("/proc/mounts", "r"), "cannot open /proc/mounts")
  for line in f:lines() do
    local dev, mp, fst = line:match("^(%S+)%s+(%S+)%s+(%S+)")
    if dev then
      -- decode kernel octal escapes: \040 = space, \011 = tab, \012 = newline
      mp = mp:gsub("\\(%d%d%d)", function(n) return string.char(tonumber(n, 8)) end)
      table.insert(mounts, { device = dev, mountpoint = mp, fstype = fst })
    end
  end
  f:close()
  return mounts
end

-- ─── Public API ───────────────────────────────────────────────────────────
local M = {}

function M.get_mounts()
  local result  = {}
  local seen_mp = {}  -- deduplicate by exact mountpoint string

  for _, m in ipairs(read_mounts()) do
    local mp = m.mountpoint
    if mp == "none" or mp == "" then goto continue end
    if seen_mp[mp]              then goto continue end
    seen_mp[mp] = true

    local s = do_statvfs(mp)
    if not s then goto continue end

    table.insert(result, {
      mountpoint = mp,
      device     = m.device,
      fstype     = m.fstype,
      total      = s.total,
      used       = s.used,
      avail      = s.avail,
    })

    ::continue::
  end

  return result
end

return M
