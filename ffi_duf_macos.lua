-- ffi_duf_macos.lua
-- macOS backend for ffi_duf.
-- Uses getmntinfo(3) (BSD) which fills a static array of struct statfs.
-- On 64-bit macOS (10.6+) getmntinfo returns 64-bit block counts.
--
-- Returned entry shape:
--   { mountpoint, device, fstype, total, used, avail }   (all sizes in bytes)

local ffi = require("ffi")
local C   = ffi.C

-- ─── FFI declarations ─────────────────────────────────────────────────────
-- macOS 64-bit struct statfs  (MFSNAMELEN=16, MAXPATHLEN=1024)
ffi.cdef[[
  typedef struct { int32_t val[2]; } fsid_t_mac;

  struct statfs_mac {
    uint32_t  f_bsize;           /* preferred block size               */
    int32_t   f_iosize;          /* optimal I/O block size             */
    uint64_t  f_blocks;          /* total data blocks (f_bsize units)  */
    uint64_t  f_bfree;           /* free  blocks                       */
    uint64_t  f_bavail;          /* free  blocks for unprivileged user */
    uint64_t  f_files;           /* total file nodes                   */
    uint64_t  f_ffree;           /* free  file nodes                   */
    fsid_t_mac f_fsid;
    uint32_t  f_owner;           /* uid_t = uint32_t on macOS          */
    uint32_t  f_type;
    uint32_t  f_flags;
    uint32_t  f_fssubtype;
    char      f_fstypename[16];  /* e.g. "apfs", "hfs", "tmpfs"       */
    char      f_mntonname[1024]; /* directory mounted on               */
    char      f_mntfromname[1024]; /* device / source                  */
    uint32_t  f_reserved[8];
  };

  int getmntinfo(struct statfs_mac **mntbufp, int flags);
]]

local MNT_NOWAIT = 2   -- return cached info without waiting for I/O

-- ─── Public API ───────────────────────────────────────────────────────────
local M = {}

function M.get_mounts()
  local result = {}
  local mntbuf = ffi.new("struct statfs_mac *[1]")
  local count  = C.getmntinfo(mntbuf, MNT_NOWAIT)
  if count <= 0 then return result end

  local mounts = mntbuf[0]
  for i = 0, count - 1 do
    local m  = mounts[i]
    local bs = tonumber(m.f_bsize)

    local total = tonumber(m.f_blocks) * bs
    local free_ = tonumber(m.f_bfree)  * bs
    local avail = tonumber(m.f_bavail) * bs

    table.insert(result, {
      mountpoint = ffi.string(m.f_mntonname),
      device     = ffi.string(m.f_mntfromname),
      fstype     = ffi.string(m.f_fstypename),
      total      = total,
      used       = total - free_,
      avail      = avail,
    })
  end

  return result
end

return M
