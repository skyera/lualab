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

    TestRunner.it("should prune deleted files during incremental index", function()
        local tmpdir = "/tmp/_test_cf_prune_" .. os.time()
        os.execute("mkdir -p " .. tmpdir)
        local f1 = io.open(tmpdir .. "/keep.c", "w")
        f1:write("This file is kept permanently.\n")
        f1:close()

        local f2 = io.open(tmpdir .. "/remove.c", "w")
        f2:write("This file will be deleted.\n")
        f2:close()

        local prune_db_path = tmpdir .. "/prune.db"
        local p_db = codefind.Database.open(prune_db_path)
        local res1 = codefind.Indexer.run(p_db, tmpdir, false)
        assert_eq(res1.indexed, 2, "Expected 2 indexed files")

        -- Delete one file on disk
        os.remove(tmpdir .. "/remove.c")

        -- Run incremental index again
        local res2 = codefind.Indexer.run(p_db, tmpdir, false)
        assert_eq(res2.pruned, 1, "Expected 1 pruned file")

        local search_res = p_db:search("permanently")
        assert_eq(#search_res, 1, "keep.c should still match")

        local search_del = p_db:search("deleted")
        assert_eq(#search_del, 0, "remove.c should no longer match")

        p_db:close()
        os.execute("rm -rf " .. tmpdir)
    end)

    TestRunner.it("should skip non-source files by default and index them with allow_all", function()
        local tmpdir = "/tmp/_test_cf_source_filter_" .. os.time()
        os.execute("mkdir -p " .. tmpdir)
        local f_src = io.open(tmpdir .. "/logic.py", "w")
        f_src:write("def calculate_tax(): return 42\n")
        f_src:close()

        local f_log = io.open(tmpdir .. "/app.log", "w")
        f_log:write("2026-09-25 ERROR Database connection failed\n")
        f_log:close()

        local f_csv = io.open(tmpdir .. "/data.csv", "w")
        f_csv:write("id,name,value\n1,alpha,99\n")
        f_csv:close()

        local test_db = tmpdir .. "/src_filter.db"
        local s_db = codefind.Database.open(test_db)

        -- 1. Default mode: only source code (logic.py) is indexed
        local res_default = codefind.Indexer.run(s_db, tmpdir, false, false)
        assert_eq(res_default.indexed, 1, "Only 1 source file should be indexed by default")
        local res_py = s_db:search("calculate_tax")
        assert_eq(#res_py, 1, "logic.py should be found")
        local res_log = s_db:search("Database")
        assert_eq(#res_log, 0, "app.log should be skipped by default")

        -- 2. allow_all mode: app.log and data.csv are also indexed
        local res_all = codefind.Indexer.run(s_db, tmpdir, false, true)
        assert_eq(res_all.indexed, 2, "2 previously skipped files should now be indexed")
        local res_log2 = s_db:search("Database")
        assert_eq(#res_log2, 1, "app.log should be found with allow_all")

        s_db:close()
        os.execute("rm -rf " .. tmpdir)
    end)

    TestRunner.it("should ignore directories specified in dotag.py (e.g., venv, boost, OpenCV)", function()
        local tmpdir = "/tmp/_test_cf_dotag_ignore_" .. os.time()
        os.execute("mkdir -p " .. tmpdir .. "/src " .. tmpdir .. "/venv " .. tmpdir .. "/boost " .. tmpdir .. "/__pycache__")
        local f_src = io.open(tmpdir .. "/src/kernel.cu", "w")
        f_src:write("__global__ void saxpy() {}\n")
        f_src:close()

        local f_venv = io.open(tmpdir .. "/venv/activate.py", "w")
        f_venv:write("# virtualenv file\n")
        f_venv:close()

        local f_boost = io.open(tmpdir .. "/boost/asio.hpp", "w")
        f_boost:write("// boost header\n")
        f_boost:close()

        local f_pyc = io.open(tmpdir .. "/__pycache__/cache.py", "w")
        f_pyc:write("# pycache\n")
        f_pyc:close()

        local test_db = tmpdir .. "/dotag_test.db"
        local d_db = codefind.Database.open(test_db)
        local res = codefind.Indexer.run(d_db, tmpdir, false, false)

        -- Only kernel.cu in src/ should be indexed; venv, boost, __pycache__ are ignored
        assert_eq(res.indexed, 1, "Only src/kernel.cu should be indexed; excluded dirs ignored")
        local res_cu = d_db:search("saxpy")
        assert_eq(#res_cu, 1, "kernel.cu (.cu extension) should be indexed and searchable")
        local res_boost = d_db:search("asio")
        assert_eq(#res_boost, 0, "boost/asio.hpp should be excluded")
        local res_venv = d_db:search("virtualenv")
        assert_eq(#res_venv, 0, "venv/activate.py should be excluded")

        d_db:close()
        os.execute("rm -rf " .. tmpdir)
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
        local f = io.open(tmpdir .. "/sample.lua", "w")
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

        assert_true(content:find("sample.lua") ~= nil, "CLI search did not output matching filename")

        os.execute("rm -rf " .. tmpdir)
    end)

    TestRunner.it("should accept --tui flag gracefully in non-interactive environment", function()
        local ret_tui1 = os.execute("luajit codefind.lua --tui < /dev/null > /dev/null 2>&1")
        assert_true(ret_tui1 == 0 or ret_tui1 == true, "--tui standalone failed")

        local ret_tui2 = os.execute("luajit codefind.lua search 'fox' --tui < /dev/null > /dev/null 2>&1")
        assert_true(ret_tui2 == 0 or ret_tui2 == true, "search --tui failed")
    end)
end)

TestRunner.describe("Suite: 6. TUI Layout Resize and Viewport Clamping", function()
    TestRunner.it("should sanitize control characters before rendering terminal text", function()
        local sanitized = codefind.sanitize_terminal_text("left\tright\r\nnext\27[2J")
        assert_eq(sanitized, "left    right  next [2J", "Terminal control characters should not move the cursor")
    end)

    TestRunner.it("should clamp scroll offset and selected index on resize", function()
        local num_results = 50
        local list_height = 20
        local selected_idx = 45
        local list_scroll_offset = 30

        -- Simulate resize to smaller terminal
        local new_height = 10
        local max_scroll = math.max(0, num_results - new_height)
        if selected_idx < list_scroll_offset + 1 then
            list_scroll_offset = selected_idx - 1
        elseif selected_idx > list_scroll_offset + new_height then
            list_scroll_offset = selected_idx - new_height
        end
        list_scroll_offset = math.max(0, math.min(list_scroll_offset, max_scroll))

        assert_true(list_scroll_offset <= max_scroll, "list_scroll_offset exceeds max_scroll")
        assert_true(selected_idx >= list_scroll_offset + 1, "selected_idx is above viewport")
        assert_true(selected_idx <= list_scroll_offset + new_height, "selected_idx is below viewport")
    end)

    TestRunner.it("should cleanly format deeply nested paths into parent/filename", function()
        local full_path = "s/RTCMSread/unit-test/RtcmUnitTest.cu"
        local fname = full_path:match("[^/\\]+$")
        local parent = full_path:match("([^/\\]+)[/\\][^/\\]+$")
        local compact = parent and (parent .. "/" .. fname) or fname
        assert_true(compact == "unit-test/RtcmUnitTest.cu", "compact path should be parent/filename")
    end)

    TestRunner.it("should identify when selection change is within page for 2-line differential update", function()
        local list_height = 10
        local list_scroll_offset = 0
        local old_idx = 3
        local new_idx = 4

        -- Calculate row coordinate in terminal: 3 header/border rows + relative index
        local old_rel = old_idx - list_scroll_offset
        local new_rel = new_idx - list_scroll_offset
        local is_same_page = (old_rel >= 1 and old_rel <= list_height) and (new_rel >= 1 and new_rel <= list_height)
        assert_true(is_same_page, "Index 3 to 4 should remain on same viewport page")
        assert_eq(3 + old_rel, 6, "Row 6 should be updated for old index")
        assert_eq(3 + new_rel, 7, "Row 7 should be updated for new index")

        -- Moving past viewport boundary triggers full scroll redraw
        local edge_new_idx = 11
        local edge_rel = edge_new_idx - list_scroll_offset
        local edge_same_page = (edge_rel >= 1 and edge_rel <= list_height)
        assert_true(not edge_same_page, "Index 11 should exceed viewport and trigger full scroll redraw")
    end)

    TestRunner.it("should trigger full screen redraw when moving to end of list across scroll boundaries", function()
        local list_scroll_offset = 0
        local old_idx = 10
        local new_idx = 15
        local list_height = 10
        local num_results = 20

        -- simulate clamp_scroll on moving down
        local old_scroll = list_scroll_offset
        local selected_idx = new_idx
        local max_scroll = math.max(0, num_results - list_height)
        if selected_idx > list_scroll_offset + list_height then
            list_scroll_offset = selected_idx - list_height
        end
        list_scroll_offset = math.max(0, math.min(list_scroll_offset, max_scroll))

        assert_true(list_scroll_offset ~= old_scroll, "Scroll offset must change when moving to end of list")
        assert_eq(list_scroll_offset, 5, "Scroll offset should now be 5")
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
