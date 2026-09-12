--[[
    test_ffi_suite.lua
    A lightweight, zero-dependency unit testing framework tailored specifically
    for LuaJIT FFI code.

    Demonstrates:
    1. Testing C struct sizes, alignment, and field offsets (ffi.sizeof, ffi.offsetof).
    2. Testing C library calls and return value assertions.
    3. Testing pointer manipulation and memory boundary conditions.
    4. Testing C error recovery and status codes without segfaults.
    5. Clean test runner with colored terminal output and exit codes for CI.
]]

local ffi = require("ffi")

-- =========================================================================
-- 1. Minimal Zero-Dependency Test Runner
-- =========================================================================
local TestRunner = {
    passed = 0,
    failed = 0,
    current_suite = ""
}

function TestRunner.describe(suite_name, fn)
    TestRunner.current_suite = suite_name
    print(string.format("\n\27[1;36m▶ Suite: %s\27[0m", suite_name))
    fn()
end

function TestRunner.it(test_name, fn)
    local ok, err = pcall(fn)
    if ok then
        TestRunner.passed = TestRunner.passed + 1
        print(string.format("  \27[32m✔\27[0m %s", test_name))
    else
        TestRunner.failed = TestRunner.failed + 1
        print(string.format("  \27[31m✘\27[0m %s", test_name))
        print(string.format("    \27[31mError: %s\27[0m", tostring(err)))
    end
end

function TestRunner.summary()
    print("\n--------------------------------------------------")
    local total = TestRunner.passed + TestRunner.failed
    if TestRunner.failed == 0 then
        print(string.format("\27[1;32mALL TESTS PASSED (%d/%d)\27[0m", TestRunner.passed, total))
        return 0
    else
        print(string.format("\27[1;31mSOME TESTS FAILED: %d passed, %d failed (Total: %d)\27[0m",
            TestRunner.passed, TestRunner.failed, total))
        return 1
    end
end

-- Assertions
local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'", msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(val, msg)
    if not val then
        error(msg or "Assertion failed: expected true value", 2)
    end
end

-- =========================================================================
-- 2. FFI Declarations to Test
-- =========================================================================
ffi.cdef[[
    typedef struct {
        uint32_t id;
        char     tag[4];
        double   value;
    } SampleRecord;

    int abs(int j);
    size_t strlen(const char *s);
    void *memset(void *s, int c, size_t n);
    int memcmp(const void *s1, const void *s2, size_t n);
]]

-- =========================================================================
-- 3. Test Cases
-- =========================================================================

TestRunner.describe("1. FFI Struct Layout and Type Verification", function()
    TestRunner.it("should match expected struct size including C padding", function()
        -- id (4) + tag (4) + double value (8) = 16 bytes
        assert_eq(ffi.sizeof("SampleRecord"), 16, "SampleRecord size mismatch")
    end)

    TestRunner.it("should match exact member memory offsets", function()
        assert_eq(ffi.offsetof("SampleRecord", "id"), 0, "offset of id")
        assert_eq(ffi.offsetof("SampleRecord", "tag"), 4, "offset of tag")
        assert_eq(ffi.offsetof("SampleRecord", "value"), 8, "offset of value")
    end)

    TestRunner.it("should allow creating and accessing struct instances", function()
        local rec = ffi.new("SampleRecord")
        rec.id = 101
        ffi.copy(rec.tag, "ABC", 3)
        rec.value = 3.1415

        assert_eq(rec.id, 101)
        assert_eq(ffi.string(rec.tag, 3), "ABC")
        assert_true(math.abs(rec.value - 3.1415) < 1e-6, "double precision check")
    end)
end)

TestRunner.describe("2. FFI Standard C Library Functions", function()
    TestRunner.it("ffi.C.abs should compute absolute values", function()
        assert_eq(ffi.C.abs(-42), 42)
        assert_eq(ffi.C.abs(42), 42)
        assert_eq(ffi.C.abs(0), 0)
    end)

    TestRunner.it("ffi.C.strlen should correctly count C string length", function()
        assert_eq(tonumber(ffi.C.strlen("hello")), 5)
        assert_eq(tonumber(ffi.C.strlen("")), 0)
    end)

    TestRunner.it("ffi.C.memset and memcmp should clear and compare memory buffers", function()
        local buf1 = ffi.new("uint8_t[128]")
        local buf2 = ffi.new("uint8_t[128]")

        ffi.C.memset(buf1, 0xAA, 128)
        ffi.C.memset(buf2, 0xAA, 128)

        assert_eq(ffi.C.memcmp(buf1, buf2, 128), 0, "buffers should be identical")

        buf2[64] = 0xBB
        assert_true(ffi.C.memcmp(buf1, buf2, 128) ~= 0, "buffers should differ")
    end)
end)

TestRunner.describe("3. Dynamic Library FFI (libsqlite3 integration)", function()
    local function load_sqlite3()
        local candidates = { "sqlite3", "libsqlite3.so.0", "libsqlite3.so", "sqlite3.dll" }
        for _, name in ipairs(candidates) do
            local ok, lib = pcall(ffi.load, name)
            if ok and lib then return lib end
        end
        return nil
    end

    TestRunner.it("should load libsqlite3 successfully via ffi.load", function()
        local sqlite = load_sqlite3()
        assert_true(sqlite ~= nil, "libsqlite3 should load")
    end)

    TestRunner.it("should create and close an in-memory database without errors", function()
        ffi.cdef[[
            typedef struct sqlite3_test sqlite3_test;
            int sqlite3_open(const char *filename, sqlite3_test **ppDb);
            int sqlite3_close(sqlite3_test *db);
        ]]
        local sqlite = load_sqlite3()
        assert_true(sqlite ~= nil, "libsqlite3 should load")
        local db = ffi.new("sqlite3_test*[1]")

        local rc_open = sqlite.sqlite3_open(":memory:", db)
        assert_eq(rc_open, 0, "sqlite3_open should return SQLITE_OK (0)")

        local rc_close = sqlite.sqlite3_close(db[0])
        assert_eq(rc_close, 0, "sqlite3_close should return SQLITE_OK (0)")
    end)
end)

TestRunner.describe("4. Error Safety and Boundary Checks", function()
    TestRunner.it("should catch ffi.cdef syntax errors safely via pcall", function()
        local ok, err = pcall(function()
            ffi.cdef[[ invalid_c_syntax @#$%; ]]
        end)
        assert_eq(ok, false, "syntax error in cdef should be caught by pcall")
    end)

    TestRunner.it("should catch missing library errors safely via pcall", function()
        local ok, err = pcall(function()
            ffi.load("non_existent_lib_12345")
        end)
        assert_eq(ok, false, "missing library should fail cleanly")
    end)
end)

TestRunner.describe("5. FFI Metatype and Operator Overloading", function()
    local Vec = require("ffi_metatype_vector")

    TestRunner.it("should create vec2 instances with operator overloading", function()
        local v1 = Vec.vec2(3, 4)
        local v2 = Vec.vec2(1, 2)

        local v_add = v1 + v2
        assert_eq(v_add.x, 4)
        assert_eq(v_add.y, 6)

        local v_sub = v1 - v2
        assert_eq(v_sub.x, 2)
        assert_eq(v_sub.y, 2)

        local v_scale = v1 * 2.0
        assert_eq(v_scale.x, 6)
        assert_eq(v_scale.y, 8)

        local v_scale_left = 2.0 * v1
        assert_eq(v_scale_left.x, 6)
        assert_eq(v_scale_left.y, 8)
    end)

    TestRunner.it("should compute vector methods (dot, length, normalized)", function()
        local v = Vec.vec2(3, 4)
        assert_eq(v:length_sq(), 25)
        assert_eq(v:length(), 5)

        local norm = v:normalized()
        assert_eq(norm.x, 0.6)
        assert_eq(norm.y, 0.8)
        assert_true(math.abs(norm:length() - 1.0) < 1e-9)

        local v2 = Vec.vec2(2, -1)
        assert_eq(v:dot(v2), 2)
    end)

    TestRunner.it("should compute vec3 cross product and formatting", function()
        local vx = Vec.vec3(1, 0, 0)
        local vy = Vec.vec3(0, 1, 0)
        local vz = vx:cross(vy)

        assert_eq(vz.x, 0)
        assert_eq(vz.y, 0)
        assert_eq(vz.z, 1)
        assert_eq(tostring(vz), "Vec3(0.00, 0.00, 1.00)")
    end)
end)

-- Exit with status code for CI / automation
local exit_code = TestRunner.summary()
os.exit(exit_code)
