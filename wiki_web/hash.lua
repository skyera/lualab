-- SHA-256 revisions: native Windows CNG, OpenSSL on Linux; no network dependency.
local ffi = require('ffi')
local M = {}
local digest_bytes
if ffi.os == 'Windows' then
    ffi.cdef[[
    long __stdcall BCryptOpenAlgorithmProvider(void **, const uint16_t *, const uint16_t *, unsigned long);
    long __stdcall BCryptHash(void *, const unsigned char *, unsigned long,
        const unsigned char *, unsigned long, unsigned char *, unsigned long);
    long __stdcall BCryptCloseAlgorithmProvider(void *, unsigned long);
    ]]
    local crypto = ffi.load('bcrypt')
    local name = ffi.new('uint16_t[7]', { 83, 72, 65, 50, 53, 54, 0 })
    digest_bytes = function(text, digest)
        local provider = ffi.new('void *[1]')
        assert(crypto.BCryptOpenAlgorithmProvider(provider, name, nil, 0) == 0, 'Cannot open SHA-256')
        local status = crypto.BCryptHash(provider[0], nil, 0, text, #text, digest, 32)
        crypto.BCryptCloseAlgorithmProvider(provider[0], 0)
        assert(status == 0, 'SHA-256 failed')
    end
else
    ffi.cdef[[unsigned char *SHA256(const unsigned char *, size_t, unsigned char *);]]
    local loaded, crypto = pcall(ffi.load, 'crypto')
    if not loaded then
        loaded, crypto = pcall(ffi.load, 'libcrypto.so.3')
        if not loaded then crypto = ffi.load('libcrypto.so.1.1') end
    end
    digest_bytes = function(text, digest)
        assert(crypto.SHA256(text, #text, digest) ~= nil, 'SHA-256 failed')
    end
end

function M.sha256(text)
    local digest, hex = ffi.new('unsigned char[32]'), {}
    digest_bytes(text, digest)
    for index = 0, 31 do hex[#hex + 1] = string.format('%02x', digest[index]) end
    return table.concat(hex)
end
return M
