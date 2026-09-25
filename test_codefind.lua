#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_codefind.lua
-- Comprehensive test suite for codefind.lua (Local Code & Document Search Engine)
--------------------------------------------------------------------------------

local codefind = require("codefind")
local Database = codefind.Database
local Indexer = codefind.Indexer

local TestRunner = {
    passed = 0,
    failed = 0
}

function TestRunner.describe(suite_name, fn)
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

local function assert_true(val, msg)
    if not val then error(msg or "Assertion failed: expected true", 2) end
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'", msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

print("================================================================================")
print("  Running Integration & Unit Test Suite for codefind.lua")
print("================================================================================")

local test_db_path = "/tmp/_test_codefind_suite_" .. os.time() .. ".db"
os.remove(test_db_path)
os.remove(test_db_path .. "-wal")
os.remove(test_db_path .. "-shm")

local db = Database.open(test_db_path)

TestRunner.describe("1. SQLite FTS5 Schema and Initialization", function()
    TestRunner.it("should initialize database object and connection handle", function()
        assert_true(db ~= nil and db.db ~= nil, "Database handle should not be nil")
    end)

    TestRunner.it("should create files and code_idx tables without error", function()
        local stats = db:get_stats()
        assert_eq(stats.total_files, 0, "Initial files count should be 0")
        assert_eq(stats.total_size, 0, "Initial total size should be 0")
    end)
end)

TestRunner.describe("2. Document Indexing and Storage", function()
    TestRunner.it("should insert files within a transaction", function()
        db:begin()
        db:index_file("src/main.lua", "main.lua", "lua", 150, 1000, "local ffi = require('ffi')\nfunction run_server() print('running') end")
        db:index_file("src/utils.c", "utils.c", "c", 300, 1000, "#include <stdio.h>\nvoid fast_copy() { memcpy(a, b, 100); }")
        db:index_file("docs/guide.md", "guide.md", "md", 600, 1000, "# Fast Search Engine\nPowered by LuaJIT FFI and SQLite FTS5.")
        db:commit()

        local stats = db:get_stats()
        assert_eq(stats.total_files, 3, "Stats should show 3 files")
        assert_true(stats.total_size >= 1050, "Total size should match sum of inserted files")
    end)

    TestRunner.it("should retrieve file metadata by path", function()
        local info = db:get_file_info("src/main.lua")
        assert_true(info ~= nil, "File info should be found")
        assert_eq(info.size, 150, "Size mismatch")
        assert_eq(info.mtime, 1000, "mtime mismatch")
    end)
end)

TestRunner.describe("3. FTS5 Search Queries & BM25 Ranking", function()
    TestRunner.it("should match exact identifiers and generate highlighted snippet", function()
        local res = db:search("run_server")
        assert_eq(#res, 1, "Expected 1 match for run_server")
        assert_eq(res[1].filepath, "src/main.lua", "Matched path mismatch")
        assert_true(res[1].snippet:find("%[%[HL%]%]run_server%[%[/HL%]%]") ~= nil, "Snippet highlight tags missing")
    end)

    TestRunner.it("should filter results by extension", function()
        local res_lua = db:search("fast", { extension = "lua" })
        assert_eq(#res_lua, 0, "Expected 0 lua files matching 'fast'")

        local res_c = db:search("fast", { extension = "c" })
        assert_eq(#res_c, 1, "Expected 1 c file matching 'fast'")
        assert_eq(res_c[1].filepath, "src/utils.c")

        local res_md = db:search("fast", { extension = "md" })
        assert_eq(#res_md, 1, "Expected 1 md file matching 'fast'")
        assert_eq(res_md[1].filepath, "docs/guide.md")
    end)

    TestRunner.it("should support prefix queries", function()
        local res = db:search("memc*")
        assert_eq(#res, 1, "Expected match for memc* prefix")
        assert_eq(res[1].filename, "utils.c")
    end)
end)

TestRunner.describe("4. Incremental Updates and Deletion", function()
    TestRunner.it("should update content without duplicate rows", function()
        db:begin()
        db:index_file("src/main.lua", "main.lua", "lua", 220, 2000, "local ffi = require('ffi')\nfunction run_server_v2() print('running v2') end")
        db:commit()

        local res_new = db:search("run_server_v2")
        assert_eq(#res_new, 1, "Expected 1 match for updated identifier")

        local stats = db:get_stats()
        assert_eq(stats.total_files, 3, "File count should still be 3 after update")
    end)

    TestRunner.it("should delete indexed files completely", function()
        db:remove_file("docs/guide.md")
        local res = db:search("Engine")
        assert_eq(#res, 0, "File should no longer be in search index")

        local stats = db:get_stats()
        assert_eq(stats.total_files, 2, "File count should be 2 after deletion")
    end)
end)

TestRunner.describe("5. CLI Invocation & Options", function()
    TestRunner.it("should execute codefind.lua --help without error", function()
        local ret = os.execute("luajit codefind.lua --help > /dev/null 2>&1")
        assert_true(ret == 0 or ret == true, "Help execution failed")
    end)

    TestRunner.it("should execute codefind.lua --test without error", function()
        local ret = os.execute("luajit codefind.lua --test > /dev/null 2>&1")
        assert_true(ret == 0 or ret == true, "Self-test execution failed")
    end)

    TestRunner.it("should index and search a fixture directory via CLI", function()
        local tmpdir = "/tmp/_test_cf_dir_" .. os.time()
        os.execute("mkdir -p " .. tmpdir)
        local f = io.open(tmpdir .. "/sample.txt", "w")
        f:write("The quick brown fox jumps over the lazy dog\n")
        f:close()

        local custom_db = tmpdir .. "/custom.db"
        local idx_cmd = string.format("luajit codefind.lua index %s --db %s > /dev/null 2>&1", tmpdir, custom_db)
        local ret_idx = os.execute(idx_cmd)
        assert_true(ret_idx == 0 or ret_idx == true, "CLI indexing failed")

        local search_out = "/tmp/_test_cf_search.txt"
        local search_cmd = string.format("luajit codefind.lua search 'lazy dog' --db %s > %s 2>&1", custom_db, search_out)
        local ret_search = os.execute(search_cmd)
        assert_true(ret_search == 0 or ret_search == true, "CLI search failed")

        local f_res = io.open(search_out, "r")
        local content = f_res and f_res:read("*a") or ""
        if f_res then f_res:close() end
        os.remove(search_out)

        assert_true(content:find("sample.txt") ~= nil, "CLI search did not output matching filename")

        os.execute("rm -rf " .. tmpdir)
    end)

    TestRunner.it("should accept --tui flag gracefully in non-interactive environment", function()
        local ret_tui1 = os.execute("luajit codefind.lua --tui < /dev/null > /dev/null 2>&1")
        assert_true(ret_tui1 == 0 or ret_tui1 == true, "--tui standalone failed")

        local ret_tui2 = os.execute("luajit codefind.lua search 'fox' --tui < /dev/null > /dev/null 2>&1")
        assert_true(ret_tui2 == 0 or ret_tui2 == true, "search --tui failed")
    end)
end)

db:close()
os.remove(test_db_path)
os.remove(test_db_path .. "-wal")
os.remove(test_db_path .. "-shm")

print("\n================================================================================")
print(string.format("  TEST SUMMARY: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print("================================================================================")

if TestRunner.failed > 0 then
    os.exit(1)
else
    print("\27[1;32mALL TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
end
