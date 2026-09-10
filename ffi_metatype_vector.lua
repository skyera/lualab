#!/usr/bin/env luajit
--[[
    ffi_metatype_vector.lua
    Demonstrates ffi.metatype in LuaJIT:
    Binding metatables, custom methods, and operator overloading (+, -, *, ==, tostring)
    directly to C struct types with zero Lua table allocation overhead.
]]

local ffi = require("ffi")

-- 1. Declare C structs for 2D and 3D Vectors
ffi.cdef[[
    typedef struct {
        double x, y;
    } vec2_t;

    typedef struct {
        double x, y, z;
    } vec3_t;
]]

-- 2. Define Vec2 Metatype with Operator Overloading
local Vec2 = {}
local vec2_mt = {
    __index = Vec2,

    __add = function(a, b)
        return ffi.new("vec2_t", a.x + b.x, a.y + b.y)
    end,

    __sub = function(a, b)
        return ffi.new("vec2_t", a.x - b.x, a.y - b.y)
    end,

    -- Scalar multiplication (supports vector * number and number * vector)
    __mul = function(a, b)
        if type(a) == "number" then
            return ffi.new("vec2_t", a * b.x, a * b.y)
        elseif type(b) == "number" then
            return ffi.new("vec2_t", a.x * b, a.y * b)
        else
            -- Component-wise product if multiplying two vectors
            return ffi.new("vec2_t", a.x * b.x, a.y * b.y)
        end
    end,

    __eq = function(a, b)
        return a.x == b.x and a.y == b.y
    end,

    __tostring = function(v)
        return string.format("Vec2(%.2f, %.2f)", v.x, v.y)
    end
}

function Vec2:dot(other)
    return self.x * other.x + self.y * other.y
end

function Vec2:length_sq()
    return self.x * self.x + self.y * self.y
end

function Vec2:length()
    return math.sqrt(self:length_sq())
end

function Vec2:normalized()
    local len = self:length()
    if len > 0 then
        return ffi.new("vec2_t", self.x / len, self.y / len)
    end
    return ffi.new("vec2_t", 0, 0)
end

-- Bind the metatable to vec2_t ctype via ffi.metatype
local vec2_type = ffi.metatype("vec2_t", vec2_mt)

-- 3. Define Vec3 Metatype
local Vec3 = {}
local vec3_mt = {
    __index = Vec3,

    __add = function(a, b)
        return ffi.new("vec3_t", a.x + b.x, a.y + b.y, a.z + b.z)
    end,

    __sub = function(a, b)
        return ffi.new("vec3_t", a.x - b.x, a.y - b.y, a.z - b.z)
    end,

    __mul = function(a, b)
        if type(a) == "number" then
            return ffi.new("vec3_t", a * b.x, a * b.y, a * b.z)
        elseif type(b) == "number" then
            return ffi.new("vec3_t", a.x * b, a.y * b, a.z * b)
        else
            return ffi.new("vec3_t", a.x * b.x, a.y * b.y, a.z * b.z)
        end
    end,

    __tostring = function(v)
        return string.format("Vec3(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
    end
}

function Vec3:dot(other)
    return self.x * other.x + self.y * other.y + self.z * other.z
end

function Vec3:cross(other)
    return ffi.new("vec3_t",
        self.y * other.z - self.z * other.y,
        self.z * other.x - self.x * other.z,
        self.x * other.y - self.y * other.x
    )
end

function Vec3:length()
    return math.sqrt(self:dot(self))
end

function Vec3:normalized()
    local len = self:length()
    if len > 0 then
        return ffi.new("vec3_t", self.x / len, self.y / len, self.z / len)
    end
    return ffi.new("vec3_t", 0, 0, 0)
end

local vec3_type = ffi.metatype("vec3_t", vec3_mt)

-- Module export
local M = {
    vec2 = vec2_type,
    vec3 = vec3_type,
}

-- If run directly from CLI, execute demo and benchmark
if not pcall(debug.getlocal, 4, 1) then
    print("=== LuaJIT ffi.metatype Vector Demo ===")
    
    local v1 = vec2_type(10, 20)
    local v2 = vec2_type(5, 15)
    print(string.format("v1: %s", tostring(v1)))
    print(string.format("v2: %s", tostring(v2)))
    print(string.format("v1 + v2 = %s", tostring(v1 + v2)))
    print(string.format("v1 - v2 = %s", tostring(v1 - v2)))
    print(string.format("v1 * 2.5 = %s", tostring(v1 * 2.5)))
    print(string.format("v1 dot v2 = %.2f", v1:dot(v2)))
    print(string.format("v1 normalized = %s (length: %.2f)", tostring(v1:normalized()), v1:normalized():length()))

    local p1 = vec3_type(1, 0, 0)
    local p2 = vec3_type(0, 1, 0)
    local p3 = p1:cross(p2)
    print(string.format("\nVec3 cross product: %s x %s = %s", tostring(p1), tostring(p2), tostring(p3)))

    -- Benchmark: Compare pure Lua table Vec vs ffi.metatype cdata Vec
    local ITERS = 1000000
    print(string.format("\n--- Benchmark: %d Vector Additions & Scale ---", ITERS))

    -- Pure Lua table approach
    local function table_vec2(x, y) return { x = x, y = y } end
    local t0 = os.clock()
    local tv = table_vec2(1.0, 2.0)
    for i = 1, ITERS do
        tv = { x = (tv.x + 0.5) * 0.999, y = (tv.y + 0.5) * 0.999 }
    end
    local time_lua = os.clock() - t0
    print(string.format("Pure Lua Table Vector: %.4f seconds", time_lua))

    -- FFI metatype cdata approach (in-place flat memory)
    local t1 = os.clock()
    local cv = vec2_type(1.0, 2.0)
    for i = 1, ITERS do
        cv.x = (cv.x + 0.5) * 0.999
        cv.y = (cv.y + 0.5) * 0.999
    end
    local time_ffi = os.clock() - t1
    print(string.format("FFI metatype C Struct: %.4f seconds", time_ffi))
    print(string.format("FFI C Struct Speedup : %.2fx faster\n", time_lua / time_ffi))
end

return M
