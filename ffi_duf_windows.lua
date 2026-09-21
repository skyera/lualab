-- ffi_duf_windows.lua
-- Windows backend for ffi_duf.
-- Uses kernel32.dll: GetLogicalDriveStringsW, GetDiskFreeSpaceExW,
--                    GetVolumeInformationW, GetDriveTypeW
--
-- Returned entry shape:
--   { mountpoint, device, fstype, total, used, avail }   (all sizes in bytes)

local ffi = require("ffi")

-- ─── Win32 FFI declarations ───────────────────────────────────────────────
-- On Windows: unsigned long = 32-bit (unlike Linux where it is 64-bit)
ffi.cdef[[
  typedef unsigned long      DWORD;
  typedef int                BOOL;
  typedef unsigned short     WCHAR;
  typedef unsigned long long ULONGLONG;
  typedef struct { ULONGLONG QuadPart; } ULARGE_INTEGER;

  DWORD GetLogicalDriveStringsW(DWORD nBufferLength, WCHAR *lpBuffer);

  BOOL  GetDiskFreeSpaceExW(
          const WCHAR        *lpDirectoryName,
          ULARGE_INTEGER     *lpFreeBytesAvailableToCaller,
          ULARGE_INTEGER     *lpTotalNumberOfBytes,
          ULARGE_INTEGER     *lpTotalNumberOfFreeBytes);

  BOOL  GetVolumeInformationW(
          const WCHAR *lpRootPathName,
          WCHAR       *lpVolumeNameBuffer,      DWORD nVolumeNameSize,
          DWORD       *lpVolumeSerialNumber,
          DWORD       *lpMaximumComponentLength,
          DWORD       *lpFileSystemFlags,
          WCHAR       *lpFileSystemNameBuffer,  DWORD nFileSystemNameSize);

  DWORD GetDriveTypeW(const WCHAR *lpRootPathName);
]]

local k32 = ffi.load("kernel32")

-- Drive type constants
local DRIVE_REMOVABLE = 2
local DRIVE_FIXED     = 3
local DRIVE_REMOTE    = 4
local DRIVE_CDROM     = 5
local DRIVE_RAMDISK   = 6

-- ─── UTF-16LE helpers (Windows WCHAR ↔ Lua ASCII) ────────────────────────
local function to_wcs(s)
  local buf = ffi.new("WCHAR[?]", #s + 1)
  for i = 1, #s do buf[i-1] = string.byte(s, i) end
  buf[#s] = 0
  return buf
end

local function from_wcs(ptr)
  local t = {}
  local i = 0
  while ptr[i] ~= 0 do
    local c = tonumber(ptr[i])
    t[#t+1] = (c < 128) and string.char(c) or "?"
    i = i + 1
  end
  return table.concat(t)
end

-- ─── Public API ───────────────────────────────────────────────────────────
local M = {}

function M.get_mounts()
  local result = {}

  -- enumerate all drive root paths: "C:\", "D:\", … (null-separated)
  local drvbuf = ffi.new("WCHAR[512]")
  local drvlen = k32.GetLogicalDriveStringsW(512, drvbuf)
  if drvlen == 0 then return result end

  local drives = {}
  local start  = 0
  for i = 0, drvlen - 1 do
    if drvbuf[i] == 0 and i > start then
      table.insert(drives, from_wcs(drvbuf + start))
      start = i + 1
    end
  end

  -- reusable output buffers
  local avail_q  = ffi.new("ULARGE_INTEGER[1]")
  local total_q  = ffi.new("ULARGE_INTEGER[1]")
  local free_q   = ffi.new("ULARGE_INTEGER[1]")
  local fs_name  = ffi.new("WCHAR[64]")
  local vol_name = ffi.new("WCHAR[256]")

  for _, drive in ipairs(drives) do
    local wdrive = to_wcs(drive)
    local dtype  = k32.GetDriveTypeW(wdrive)

    -- skip unknown / no-root-dir drive types
    if dtype < DRIVE_REMOVABLE or dtype > DRIVE_RAMDISK then goto continue end

    if k32.GetDiskFreeSpaceExW(wdrive, avail_q, total_q, free_q) == 0 then
      goto continue
    end

    local total = tonumber(total_q[0].QuadPart)
    local free_ = tonumber(free_q[0].QuadPart)
    local avail = tonumber(avail_q[0].QuadPart)

    -- get filesystem type (keep original casing: "NTFS", "FAT32", "FUSE-SSHFS", …)
    local fstype = "unknown"
    local device = drive
    if k32.GetVolumeInformationW(wdrive, vol_name, 256, nil, nil, nil, fs_name, 64) ~= 0 then
      fstype = from_wcs(fs_name)
      local vname = from_wcs(vol_name)
      if vname ~= "" then device = vname end
    end

    -- keep trailing backslash: "C:\" matches duf display
    local mp = drive

    table.insert(result, {
      mountpoint = mp,
      device     = device,
      fstype     = fstype,
      total      = total,
      used       = total - free_,
      avail      = avail,
    })

    ::continue::
  end

  return result
end

return M
