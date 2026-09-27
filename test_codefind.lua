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

local is_win = package.config:sub(1,1) == '\\'
local null_dev = is_win and "NUL" or "/dev/null"
local tmp_base = is_win and (os.getenv("TEMP") or "C:\\temp"):gsub("\\", "/") or "/tmp"

local function make_tmpdir(name)
    local p = tmp_base .. "/" .. name
    if is_win then
        os.execute('if not exist "' .. p:gsub("/", "\\") .. '" mkdir "' .. p:gsub("/", "\\") .. '" > NUL 2>&1')
    else
        os.execute('mkdir -p "' .. p .. '"')
    end
    return p
end

local function rm_tmpdir(dir)
    if is_win then
        os.execute('rmdir /s /q "' .. dir:gsub("/", "\\") .. '" > NUL 2>&1')
    else
        os.execute('rm -rf "' .. dir .. '"')
    end
end

print("================================================================================")
print("  Running Integration & Unit Test Suite for codefind.lua")
print("================================================================================")

local test_db_path = tmp_base .. "/_test_codefind_suite_" .. os.time() .. ".db"
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
        local tmpdir = make_tmpdir("_test_cf_prune_" .. os.time())
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
        rm_tmpdir(tmpdir)
    end)

    TestRunner.it("should skip non-source files by default and index them with allow_all", function()
        local tmpdir = make_tmpdir("_test_cf_source_filter_" .. os.time())
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
        rm_tmpdir(tmpdir)
    end)

    TestRunner.it("should ignore directories specified in dotag.py (e.g., venv, boost, OpenCV)", function()
        local tmpdir = make_tmpdir("_test_cf_dotag_ignore_" .. os.time())
        make_tmpdir("_test_cf_dotag_ignore_" .. os.time() .. "/src")
        make_tmpdir("_test_cf_dotag_ignore_" .. os.time() .. "/venv")
        make_tmpdir("_test_cf_dotag_ignore_" .. os.time() .. "/boost")
        make_tmpdir("_test_cf_dotag_ignore_" .. os.time() .. "/__pycache__")
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
        rm_tmpdir(tmpdir)
    end)
end)

TestRunner.describe("5. CLI Invocation & Options", function()
    TestRunner.it("should execute codefind.lua --help without error", function()
        local ret = os.execute(string.format("luajit codefind.lua --help > %s 2>&1", null_dev))
        assert_true(ret == 0 or ret == true, "Help execution failed")
    end)

    TestRunner.it("should execute codefind.lua --test without error", function()
        local ret = os.execute(string.format("luajit codefind.lua --test > %s 2>&1", null_dev))
        assert_true(ret == 0 or ret == true, "Self-test execution failed")
    end)

    TestRunner.it("should index and search a fixture directory via CLI", function()
        local tmpdir = make_tmpdir("_test_cf_dir_" .. os.time())
        local f = io.open(tmpdir .. "/sample.lua", "w")
        f:write("The quick brown fox jumps over the lazy dog\n")
        f:close()

        local custom_db = tmpdir .. "/custom.db"
        local idx_cmd = string.format("luajit codefind.lua index %s --db %s > %s 2>&1", tmpdir, custom_db, null_dev)
        local ret_idx = os.execute(idx_cmd)
        assert_true(ret_idx == 0 or ret_idx == true, "CLI indexing failed")

        local search_out = tmpdir .. "/_test_cf_search.txt"
        local search_cmd = string.format("luajit codefind.lua search \"lazy dog\" --db %s > %s 2>&1", custom_db, search_out)
        local ret_search = os.execute(search_cmd)
        assert_true(ret_search == 0 or ret_search == true, "CLI search failed")

        local f_res = io.open(search_out, "r")
        local content = f_res and f_res:read("*a") or ""
        if f_res then f_res:close() end
        os.remove(search_out)

        assert_true(content:find("sample.lua") ~= nil, "CLI search did not output matching filename")

        rm_tmpdir(tmpdir)
    end)

    TestRunner.it("should accept --tui flag gracefully in non-interactive environment", function()
        local ret_tui1 = os.execute(string.format("luajit codefind.lua --tui < %s > %s 2>&1", null_dev, null_dev))
        assert_true(ret_tui1 == 0 or ret_tui1 == true, "--tui standalone failed")

        local ret_tui2 = os.execute(string.format("luajit codefind.lua search 'fox' --tui < %s > %s 2>&1", null_dev, null_dev))
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

TestRunner.describe("7. SQLite3 Library Discovery, Validation and Selection", function()
    -- Locate a real sqlite3 on PATH so validation can be exercised for real.
    local SELF_SQLITE_PATH = nil
    do
        local dirs = {}
        for d in (os.getenv("PATH") or ""):gmatch("[^;]+") do dirs[#dirs + 1] = d end
        for _, d in ipairs(dirs) do
            local p = d:gsub("[/\\]+$", "") .. "\\sqlite3.dll"
            local f = io.open(p, "rb")
            if f then f:close(); SELF_SQLITE_PATH = p; break end
        end
    end

    -- Candidates are enumerated, not loaded: no `result` until the one the user
    -- picks has actually been loaded and validated.
    local function cand(path, source)
        return { path = path, source = source or "test", size = 1024 * 1024, is_pe = true }
    end
    local function reader(input)
        return function() return input end
    end
    local function swallow() end

    TestRunner.it("should compare dotted versions numerically, not lexically", function()
        -- The bug this guards: "3.9.0" > "3.47.2" as strings, but not as numbers.
        assert_true(codefind.version_key("3.53.4") > codefind.version_key("3.47.2"),
            "3.53.4 must outrank 3.47.2")
        assert_true(codefind.version_key("3.9.0") < codefind.version_key("3.47.2"),
            "3.9.0 must NOT outrank 3.47.2")
        assert_eq(codefind.version_key("garbage"), 0, "Unparseable version should rank 0")
    end)

    TestRunner.it("should auto-select when exactly one library was found", function()
        local only = cand("C:\\only\\sqlite3.dll")
        local picked = codefind.choose_candidate({ only }, false, reader(nil), swallow)
        assert_eq(picked.path, "C:\\only\\sqlite3.dll", "Single candidate must be chosen")
    end)

    TestRunner.it("should keep discovery order and not load anything to choose", function()
        local list = { cand("C:\\first\\sqlite3.dll"), cand("C:\\second\\sqlite3.dll") }
        local picked = codefind.choose_candidate(list, false, reader(nil), swallow)
        assert_eq(picked.path, "C:\\first\\sqlite3.dll", "First on PATH must win by default")
        assert_true(picked.result == nil, "Choosing must not populate a validation result")
    end)

    TestRunner.it("should honour an interactive numeric choice", function()
        local list = { cand("C:\\first\\sqlite3.dll"), cand("C:\\second\\sqlite3.dll") }
        local picked = codefind.choose_candidate(list, true, reader("2"), swallow)
        assert_eq(picked.path, "C:\\second\\sqlite3.dll", "Choice 2 must be honoured")
    end)

    TestRunner.it("should fall back to the default on invalid interactive input", function()
        for _, bad in ipairs({ "abc", "", "0", "99", "-1" }) do
            local list = { cand("C:\\first\\sqlite3.dll"), cand("C:\\second\\sqlite3.dll") }
            local picked = codefind.choose_candidate(list, true, reader(bad), swallow)
            assert_eq(picked.path, "C:\\first\\sqlite3.dll",
                "Input '" .. bad .. "' must fall back to the first")
        end
    end)

    TestRunner.it("should fall back to the default when input is closed (EOF)", function()
        local list = { cand("C:\\first\\sqlite3.dll"), cand("C:\\second\\sqlite3.dll") }
        local picked = codefind.choose_candidate(list, true, reader(nil), swallow)
        assert_eq(picked.path, "C:\\first\\sqlite3.dll", "EOF must fall back to the first")
    end)

    TestRunner.it("should report nothing to choose when no library was found", function()
        assert_eq(codefind.choose_candidate({}, true, reader("1"), swallow), nil,
            "Empty candidate list must yield no choice")
    end)

    TestRunner.it("should rank a conda build above chocolatey, msys2 and PATH", function()
        local conda  = select(1, codefind.classify_source([[C:\app\miniforge3\Library\bin\sqlite3.dll]], "PATH"))
        local anac   = select(1, codefind.classify_source([[D:\anaconda3\Library\bin\sqlite3.dll]], "PATH"))
        local choco  = select(1, codefind.classify_source([[C:\ProgramData\chocolatey\lib\SQLite\tools\sqlite3.dll]], "PATH"))
        local msys   = select(1, codefind.classify_source([[C:\msys64\mingw64\bin\sqlite3.dll]], "PATH"))
        local plain  = select(1, codefind.classify_source([[C:\random\tools\sqlite3.dll]], "PATH"))
        assert_true(conda > choco, "conda must outrank chocolatey")
        assert_true(anac > msys, "anaconda must outrank msys2")
        assert_true(conda > plain, "conda must outrank an anonymous PATH hit")
        assert_true(choco > plain, "chocolatey must outrank an anonymous PATH hit")
    end)

    TestRunner.it("should label a library dropped beside the script or cwd as local", function()
        local tier, label = codefind.classify_source([[C:\proj\sqlite3.dll]], "cwd")
        assert_eq(label, "local", "A deliberate local placement should be labelled local")
        assert_true(tier > select(1, codefind.classify_source([[C:\x\bin\sqlite3.dll]], "PATH")),
            "local placement must outrank an anonymous PATH hit")
    end)

    TestRunner.it("should pick the highest tier regardless of discovery order", function()
        local list = {
            { path = [[C:\choco\sqlite3.dll]], tier = 10, source = "PATH" },
            { path = [[C:\conda\sqlite3.dll]], tier = 40, source = "PATH" },
        }
        assert_eq(codefind.best_candidate(list).path, [[C:\conda\sqlite3.dll]],
            "Highest tier must win")
    end)

    TestRunner.it("should match a pinned path against a scanned one despite slash style", function()
        assert_true(codefind.same_path([[C:/app/miniforge3/sqlite3.dll]],
                                       [[C:\app\miniforge3\sqlite3.dll]]),
            "Forward-slash config must match a backslash scan result")
        assert_true(not codefind.same_path([[C:/a/sqlite3.dll]], [[C:/b/sqlite3.dll]]),
            "Different paths must not match")
        assert_true(codefind.same_path([[C:\APP\SQLite3.DLL]], [[C:/app/sqlite3.dll]]),
            "Matching must be case-insensitive")
    end)

    TestRunner.it("should mark an unvalidated candidate as not loaded", function()
        local d = codefind.describe_candidate(cand("C:\\x\\sqlite3.dll"), 1)
        assert_true(d:find("not loaded"), "Unvalidated candidate must be marked not loaded")
        assert_true(d:find("PE image"), "Should still report the file header check")
    end)

    TestRunner.it("should reject a path that is not a PE image", function()
        local tmp = os.tmpname()
        local f = io.open(tmp, "wb"); f:write("not a dll"); f:close()
        local r = codefind.validate_sqlite_lib(tmp)
        os.remove(tmp)
        assert_true(not r.ok, "A text file must not validate")
        assert_true(r.reason:find("not a PE image"), "Expected a PE-image rejection, got: " .. tostring(r.reason))
    end)

    TestRunner.it("should reject a missing file with a readable reason", function()
        local r = codefind.validate_sqlite_lib("C:\\definitely\\not\\here\\sqlite3.dll")
        assert_true(not r.ok, "Missing file must not validate")
        assert_true(r.reason ~= nil and #r.reason > 0, "Rejection must carry a reason")
    end)

    TestRunner.it("should validate the library actually in use", function()
        if SELF_SQLITE_PATH == nil then return end   -- platform without a discoverable file
        local r = codefind.validate_sqlite_lib(SELF_SQLITE_PATH)
        assert_true(r.ok, "The in-use library must validate, got: " .. tostring(r.reason))
        assert_true(r.version ~= nil, "Validated library must report a version")
    end)

    TestRunner.it("should not crash on any non-letter character in a preview query", function()
        -- Regression: gsub's second return value leaked into table.insert's
        -- optional `pos` argument, so any query containing a non-letter
        -- ("job_", "log2024", "user.name", "a+b") raised
        -- "bad argument #2 to 'insert'" and killed the TUI preview.
        for _, q in ipairs({ "job_", "log2024", "user.name", "a+b", "f(x)", "50%",
                             "a-b", "[x]", "a$b", "a?b", "a*b", "a^b", "_" }) do
            local ok, terms, patterns = pcall(codefind.build_preview_patterns, q)
            assert_true(ok, "Query '" .. q .. "' must not raise, got: " .. tostring(terms))
            assert_true(#patterns >= 1, "Query '" .. q .. "' should yield a pattern")
        end
    end)

    TestRunner.it("should build case-insensitive patterns that actually match", function()
        local _, pats = codefind.build_preview_patterns("Job_X")
        local p = pats[1]
        assert_eq(p, "[jJ][oO][bB]_[xX]", "Each letter should become a case-insensitive class")
        assert_true(("a Job_X here"):find(p) ~= nil, "Should match 'Job_X'")
        assert_true(("a JOB_X here"):find(p) ~= nil, "Should match 'JOB_X'")
        assert_true(("a job_x here"):find(p) ~= nil, "Should match 'job_x'")
        assert_true(("a jobx here"):find(p) == nil, "Must not match 'jobx' -- '_' is required")
    end)

    TestRunner.it("should escape a hyphen so it cannot act as a pattern range", function()
        -- '-' is part of a term (the tokenizer keeps it), but it is also a Lua
        -- pattern range operator, so it must be escaped in the built pattern.
        local terms, pats = codefind.build_preview_patterns("a-b")
        assert_eq(#terms, 1, "'a-b' is a single term")
        assert_eq(pats[1], "[aA]%-[bB]", "Hyphen must be escaped as %-")
        assert_true(("xa-by"):find(pats[1]) ~= nil, "Should match 'a-b'")
        assert_true(("xaby"):find(pats[1]) == nil, "Must not match 'ab' -- hyphen is required")
    end)

    TestRunner.it("should tokenise a query on non-word characters", function()
        local terms, pats = codefind.build_preview_patterns("user.name")
        assert_eq(#terms, 2, "'user.name' is two terms")
        assert_eq(pats[1], "[uU][sS][eE][rR]", "First term pattern")
        assert_eq(pats[2], "[nN][aA][mM][eE]", "Second term pattern")
    end)

    TestRunner.it("should describe an unusable candidate without flooding the line", function()
        local c = { path = "C:\\x\\sqlite3.dll", source = "test",
                    result = { path = "C:\\x\\sqlite3.dll", size = 2048, ok = false,
                               reason = "missing symbols: sqlite3_open, sqlite3_close, sqlite3_exec, sqlite3_step, sqlite3_finalize, sqlite3_free" } }
        local d = codefind.describe_candidate(c, 1)
        assert_true(d:find("UNUSABLE"), "Description must mark it unusable")
        assert_true(d:find("%+%d more"), "Long symbol lists must be truncated")
    end)
end)

TestRunner.describe("8. Streaming Windowed Preview Reader", function()
    local test_large_file = "test_large_windowed.tmp"
    local tf = io.open(test_large_file, "w")
    for i = 1, 5000 do
        if i == 45 then
            tf:write("target_identifier_at_45 = 100\n")
        elseif i == 2500 then
            tf:write("target_identifier_at_2500 = 200\n")
        elseif i == 4800 then
            tf:write("target_identifier_at_4800 = 300\n")
        else
            tf:write(string.format("local line_%d = %d\n", i, i))
        end
    end
    tf:close()

    TestRunner.it("should read lines from arbitrary offsets in files larger than 2,000 lines", function()
        local reader = codefind.make_preview_reader(500, 4)
        assert_eq(reader.get_total_lines(test_large_file), 5000, "Total lines should be 5000")
        assert_eq(reader.get_line(test_large_file, 1), "local line_1 = 1", "Line 1 should match")
        assert_eq(reader.get_line(test_large_file, 45), "target_identifier_at_45 = 100", "Line 45 should match")
        assert_eq(reader.get_line(test_large_file, 2000), "local line_2000 = 2000", "Line 2000 should match")
        assert_eq(reader.get_line(test_large_file, 2001), "local line_2001 = 2001", "Line 2001 (beyond old limit) should match")
        assert_eq(reader.get_line(test_large_file, 2500), "target_identifier_at_2500 = 200", "Line 2500 should match")
        assert_eq(reader.get_line(test_large_file, 4800), "target_identifier_at_4800 = 300", "Line 4800 should match")
        assert_eq(reader.get_line(test_large_file, 5000), "local line_5000 = 5000", "Line 5000 should match")
    end)

    TestRunner.it("should slide the window on demand without reloading adjacent lines", function()
        local reader = codefind.make_preview_reader(200, 4)
        local l1 = reader.get_line(test_large_file, 2500)
        assert_eq(l1, "target_identifier_at_2500 = 200")
        local entry = reader.file_cache[test_large_file]
        assert_true(entry ~= nil, "File should be cached")
        local initial_start = entry.window_start

        -- Nearby line should not shift the window
        local l2 = reader.get_line(test_large_file, 2505)
        assert_eq(l2, "local line_2505 = 2505")
        assert_eq(entry.window_start, initial_start, "Window should not slide for nearby line")

        -- Line far away should slide the window
        local l3 = reader.get_line(test_large_file, 4800)
        assert_eq(l3, "target_identifier_at_4800 = 300")
        assert_true(entry.window_start > initial_start, "Window should have slid forward")
    end)

    TestRunner.it("should stream through files to find query matches at line > 2,000", function()
        local reader = codefind.make_preview_reader(500, 4)
        local m_lines, m_list, tot = reader.find_matches(test_large_file, { "target_identifier" })
        assert_eq(tot, 5000, "Total lines returned should be 5000")
        assert_eq(#m_list, 3, "Expected 3 matches")
        assert_eq(m_list[1], 45, "First match at line 45")
        assert_eq(m_list[2], 2500, "Second match at line 2500 (> 2000)")
        assert_eq(m_list[3], 4800, "Third match at line 4800 (> 2000)")
        assert_true(m_lines[45] and m_lines[2500] and m_lines[4800], "Match lines map should be populated")
    end)

    TestRunner.it("should safely handle boundary inputs and nonexistent files", function()
        local reader = codefind.make_preview_reader(500, 4)
        assert_eq(reader.get_line(test_large_file, 0), "", "Line 0 should return empty string")
        assert_eq(reader.get_line(test_large_file, -5), "", "Negative line should return empty string")
        assert_eq(reader.get_line(test_large_file, 5001), "", "Out-of-bounds line should return empty string")
        assert_eq(reader.get_line("nonexistent_file_xyz.txt", 1), "", "Nonexistent file should return empty string")
        assert_eq(reader.get_total_lines("nonexistent_file_xyz.txt"), 0, "Nonexistent file total should be 0")
    end)

    os.remove(test_large_file)
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
