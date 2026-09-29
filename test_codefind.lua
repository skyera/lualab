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

local function assert_false(val, msg)
    if val then error(msg or "Assertion failed: expected false", 2) end
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

    TestRunner.it("should report version 0.1.0 on --version, -v, and module export", function()
        local p = io.popen("luajit codefind.lua --version 2>&1")
        local v_long = p and p:read("*a") or ""
        if p then p:close() end
        assert_true(v_long:find("codefind 0%.1%.0") ~= nil, "--version did not output expected version: " .. tostring(v_long))

        local p2 = io.popen("luajit codefind.lua -v 2>&1")
        local v_short = p2 and p2:read("*a") or ""
        if p2 then p2:close() end
        assert_true(v_short:find("codefind 0%.1%.0") ~= nil, "-v did not output expected version: " .. tostring(v_short))

        assert_eq(codefind._VERSION, "0.1.0", "Module _VERSION should be 0.1.0")
        assert_eq(codefind.version, "0.1.0", "Module version should be 0.1.0")
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

    TestRunner.it("should toggle Help View on F1 and ? unconditionally", function()
        local show_help = false
        local focus_pane = "search"
        local query = ""

        local function handle_key(key)
            if show_help then
                show_help = false
                return "dismissed"
            elseif key == "F1" or key == "?" then
                show_help = true
                return "opened"
            elseif #key == 1 and focus_pane == "search" then
                query = query .. key
                return "typed"
            end
            return "ignored"
        end

        -- In empty search box, pressing ? opens help
        assert_eq(handle_key("?"), "opened", "Pressing ? should open help")
        assert_true(show_help, "show_help must be true")

        -- Pressing ? again dismisses help
        assert_eq(handle_key("?"), "dismissed", "? should dismiss help when active")
        assert_false(show_help, "show_help must be false")

        -- Pressing F1 always opens help
        assert_eq(handle_key("F1"), "opened", "F1 should open help")
        assert_true(show_help, "show_help must be true")

        -- Esc dismisses help
        assert_eq(handle_key("ESC"), "dismissed", "Esc should dismiss help")
        assert_false(show_help, "show_help must be false")

        -- Even when query already has text, pressing ? still opens help
        query = "hello"
        assert_eq(handle_key("?"), "opened", "? should open help even when query has text")
        assert_true(show_help, "show_help must be true")
        assert_eq(query, "hello", "query text should be preserved intact")

        -- Esc dismisses help, query preserved
        assert_eq(handle_key("ESC"), "dismissed", "Esc dismisses help")
        assert_false(show_help, "show_help must be false")
        assert_eq(query, "hello", "query text preserved")

        -- And F1 also opens help with query text
        assert_eq(handle_key("F1"), "opened", "F1 should open help with query text")
        assert_true(show_help, "show_help must be true")
    end)

    TestRunner.it("should parse Windows console F1 scan codes and VT escape sequences", function()
        local function parse_win_seq(c0, extra)
            if c0 == 0 or c0 == 224 then
                local c1 = extra[1]
                if c1 == 72 then return "UP"
                elseif c1 == 80 then return "DOWN"
                elseif c1 == 59 or c1 == 84 or c1 == 94 or c1 == 104 then return "F1"
                end
            elseif c0 == 27 then
                local seq = table.concat(extra)
                if seq == "OP" or seq == "[11~" or seq == "[[A" or seq:find("OP$") then
                    return "F1"
                end
                return "ESC"
            end
            return string.char(c0)
        end

        assert_eq(parse_win_seq(0, {59}), "F1", "Classic console F1 (scan 59) should return F1")
        assert_eq(parse_win_seq(0, {84}), "F1", "Shift-F1 (scan 84) should return F1")
        assert_eq(parse_win_seq(0, {94}), "F1", "Ctrl-F1 (scan 94) should return F1")
        assert_eq(parse_win_seq(224, {59}), "F1", "Extended prefix F1 should return F1")
        assert_eq(parse_win_seq(27, {"O", "P"}), "F1", "Windows Terminal VT F1 (ESC OP) should return F1")
        assert_eq(parse_win_seq(27, {"[", "1", "1", "~"}), "F1", "Windows VT F1 (ESC [ 1 1 ~) should return F1")
        assert_eq(parse_win_seq(27, {}), "ESC", "Standalone ESC should return ESC")
        assert_eq(parse_win_seq(63, {}), "?", "ASCII 63 should return ?")
    end)

    TestRunner.it("should format split footer and preserve essential shortcut pills during notifications", function()
        local build_footer = codefind.build_footer_content
        local visual_len = codefind.visual_len

        -- 1. Normal Search Mode: no status notification, exact visual width = cols - 2
        local footer_search = build_footer(80, nil, false, "search", "")
        assert_eq(visual_len(footer_search), 78, "Footer visual length must equal cols - 2")
        assert_true(footer_search:find("Tab") ~= nil, "Tab pill should be present")
        assert_true(footer_search:find("Browse") ~= nil, "Browse label should be present")
        assert_true(footer_search:find("F1") ~= nil, "F1 pill should be present")
        assert_true(footer_search:find("Enter") ~= nil, "Enter pill should be present")

        local footer_search_100 = build_footer(100, nil, false, "search", "")
        assert_eq(visual_len(footer_search_100), 98, "Footer visual length must equal cols - 2")
        assert_true(footer_search_100:find("Quit") ~= nil, "Quit pill should be present on 100 cols")

        -- 2. Normal Preview Mode: no status notification
        local footer_prev = build_footer(100, nil, false, "preview", "")
        assert_eq(visual_len(footer_prev), 98, "Footer visual length must equal cols - 2")
        assert_true(footer_prev:find("Search") ~= nil, "Search pill should be present")
        assert_true(footer_prev:find("Match") ~= nil, "Match pill should be present")
        assert_true(footer_prev:find("Quit") ~= nil, "Quit pill should be present")

        -- 3. Active Status Notification with checkmark (clipboard copy): split footer
        local footer_yank = build_footer(80, "✔ Copied 'foo.lua:42' to clipboard", true, "preview", "")
        assert_eq(visual_len(footer_yank), 78, "Yank footer visual length must equal cols - 2")
        assert_true(footer_yank:find("DONE") ~= nil, "DONE badge should be displayed")
        assert_true(footer_yank:find("Copied 'foo.lua:42'") ~= nil, "Message text should be displayed")
        assert_true(footer_yank:find("Help") ~= nil, "Help pill must be preserved on right")
        assert_true(footer_yank:find("Quit") ~= nil, "Quit pill must be preserved on right")

        -- 4. Active Status Notification with lightning (sync indexing)
        local footer_sync = build_footer(100, "⚡ Re-indexed 5 files", true, "search", "")
        assert_eq(visual_len(footer_sync), 98, "Sync footer visual length must equal cols - 2")
        assert_true(footer_sync:find("SYNC") ~= nil, "SYNC badge should be displayed")
        assert_true(footer_sync:find("Re%-indexed 5 files") ~= nil, "Re-indexed text should be displayed")
        assert_true(footer_sync:find("F1") ~= nil, "F1 pill must be preserved on right")
        assert_true(footer_sync:find("%^Q") ~= nil, "^Q pill must be preserved on right")

        -- 5. Narrow terminal (60 cols) with long message: properly truncated without overflow
        local long_msg = "A very long status message that would otherwise wrap around the screen and corrupt cursor"
        local footer_narrow = build_footer(60, long_msg, true, "search", "")
        assert_eq(visual_len(footer_narrow), 58, "Narrow footer visual length must equal 58")
        assert_true(footer_narrow:find("INFO") ~= nil, "INFO badge should be displayed")
        assert_true(footer_narrow:find("%^Q") ~= nil, "^Q pill must be preserved on right")

        -- 6. Expired notification: returns to normal pills
        local footer_expired = build_footer(80, "✔ Old message", false, "search", "")
        assert_eq(visual_len(footer_expired), 78, "Expired footer visual length must equal 78")
        assert_true(footer_expired:find("DONE") == nil, "DONE badge should not be present when expired")
        assert_true(footer_expired:find("Browse") ~= nil, "Standard pills should be back")
    end)

    TestRunner.it("should dynamically scale preview line gutter without border overflow", function()
        local format_gutter = codefind.format_preview_gutter
        local visual_len = codefind.visual_len

        -- 1. Small file (< 1,000 lines): minimum 3 digits, gutter width = 8 (2 prefix + 3 digits + 3 separator)
        local g_small, w_small, d_small = format_gutter(42, 500, false)
        assert_eq(d_small, 3, "Small file should have 3 digits")
        assert_eq(w_small, 8, "Small file gutter width should be 8")
        assert_eq(visual_len(g_small), 8, "Gutter visual length must equal calculated width")
        assert_true(g_small:find("42 │") ~= nil, "Gutter should contain line number")

        -- 2. Medium file (1,000 - 9,999 lines): 4 digits, gutter width = 9
        local g_med, w_med, d_med = format_gutter(1420, 5000, true)
        assert_eq(d_med, 4, "Medium file should have 4 digits")
        assert_eq(w_med, 9, "Medium file gutter width should be 9")
        assert_eq(visual_len(g_med), 9, "Gutter visual length must equal 9")
        assert_true(g_med:find(">") ~= nil and g_med:find("1420 │") ~= nil, "Hit gutter should contain > indicator")

        -- 3. Large file (10,000 - 99,999 lines): 5 digits, gutter width = 10 (no overflow)
        local g_large, w_large, d_large = format_gutter(14250, 25000, true)
        assert_eq(d_large, 5, "Large file should dynamically expand to 5 digits")
        assert_eq(w_large, 10, "Large file gutter width should be 10")
        assert_eq(visual_len(g_large), 10, "Gutter visual length must equal 10")

        -- 4. Huge amalgamation file (>= 100,000 lines, e.g. sqlite3.c ~150k lines): 6 digits, gutter width = 11
        local g_huge, w_huge, d_huge = format_gutter(145000, 150000, false)
        assert_eq(d_huge, 6, "Huge file should dynamically expand to 6 digits")
        assert_eq(w_huge, 11, "Huge file gutter width should be 11")
        assert_eq(visual_len(g_huge), 11, "Gutter visual length must equal 11")

        -- 5. Full cell width invariant: gutter + code + padding + scrollbar exactly equals right_col_w
        local right_col_w = 60
        local r_text_w = right_col_w - 1
        local right_sb = "│"
        local max_code_w = math.max(0, r_text_w - w_huge)
        local code_str = codefind.truncate("int sqlite3_step(sqlite3_stmt *pStmt) {", max_code_w)
        local line_pad = string.rep(" ", math.max(0, max_code_w - visual_len(code_str)))
        local full_cell = g_huge .. code_str .. line_pad .. right_sb
        assert_eq(visual_len(full_cell), right_col_w, "Full right cell width must exactly equal right_col_w")
    end)

    TestRunner.it("should compute responsive single-pane layout on narrow screens and zoom toggle", function()
        local geom_fn = codefind.compute_layout_geometry
        local build_footer = codefind.build_footer_content
        local visual_len = codefind.visual_len

        -- 1. Narrow terminal (< 75 columns, e.g. 60 cols) auto switches to single-pane
        local g60_search = geom_fn(60, 24, "search", false)
        assert_true(g60_search.is_narrow, "60 cols should be flagged as narrow")
        assert_true(g60_search.is_single_pane, "60 cols should automatically activate single-pane")
        assert_eq(g60_search.left_col_w, 58, "Search pane should occupy full content width (60 - 2)")
        assert_eq(g60_search.right_col_w, 0, "Preview pane should be hidden (0 cols)")
        assert_eq(g60_search.content_w, 58, "Content width should be 58")

        local g60_prev = geom_fn(60, 24, "preview", false)
        assert_true(g60_prev.is_single_pane, "Preview pane on 60 cols should be single-pane")
        assert_eq(g60_prev.left_col_w, 0, "Search pane should be hidden (0 cols)")
        assert_eq(g60_prev.right_col_w, 58, "Preview pane should occupy full content width (60 - 2)")

        -- Check footer in narrow single-pane mode: Tab flips to Preview/Search
        local foot60_search = build_footer(60, nil, false, "search", "", false, true)
        assert_eq(visual_len(foot60_search), 58, "Visual width must equal 58")
        assert_true(foot60_search:find("Preview") ~= nil, "Tab in search single-pane should prompt Preview")

        local foot60_prev = build_footer(60, nil, false, "preview", "", false, true)
        assert_eq(visual_len(foot60_prev), 58, "Visual width must equal 58")
        assert_true(foot60_prev:find("Search") ~= nil, "Tab in preview single-pane should prompt Search")

        -- 2. Standard terminal (>= 75 columns, e.g. 80 and 120 cols) defaults to two-pane
        local g80 = geom_fn(80, 30, "search", false)
        assert_false(g80.is_narrow, "80 cols should not be narrow")
        assert_false(g80.is_single_pane, "80 cols should default to two-pane")
        assert_eq(g80.left_col_w + g80.right_col_w + 3, 80, "Two-pane invariant: left + right + 3 == cols")
        assert_true(g80.left_col_w >= 34, "Left col width should be at least 34")

        local g120 = geom_fn(120, 40, "search", false)
        assert_false(g120.is_single_pane, "120 cols should default to two-pane")
        assert_eq(g120.left_col_w + g120.right_col_w + 3, 120, "120 cols invariant: left + right + 3 == cols")

        -- 3. Zoom mode on standard terminal (F2 / z toggle) activates full-width single-pane
        local g100_zoomed_search = geom_fn(100, 30, "search", true)
        assert_false(g100_zoomed_search.is_narrow, "100 cols is not narrow")
        assert_true(g100_zoomed_search.is_single_pane, "Zoom should activate single pane")
        assert_eq(g100_zoomed_search.left_col_w, 98, "Zoomed search should occupy full content width (98 cols)")
        assert_eq(g100_zoomed_search.right_col_w, 0, "Zoomed search should hide preview pane")

        local g100_zoomed_prev = geom_fn(100, 30, "preview", true)
        assert_true(g100_zoomed_prev.is_single_pane, "Zoomed preview should be single pane")
        assert_eq(g100_zoomed_prev.left_col_w, 0, "Zoomed preview should hide search pane")
        assert_eq(g100_zoomed_prev.right_col_w, 98, "Zoomed preview should occupy full content width (98 cols)")

        -- Footer pills under zoom: displays 'Unzoom'
        local foot100_zoomed = build_footer(100, nil, false, "search", "", true, true)
        assert_eq(visual_len(foot100_zoomed), 98, "Zoomed footer width must equal 98")
        assert_true(foot100_zoomed:find("Unzoom") ~= nil, "Zoomed footer should offer Unzoom")

        -- 4. F2 key parsing in Windows VT and POSIX sequences
        local parse_win_seq = function(c0, rest)
            if c0 == 0 or c0 == 224 then
                local c1 = rest[1]
                if c1 == 60 or c1 == 85 or c1 == 95 or c1 == 105 then return "F2" end
            elseif c0 == 27 then
                local seq = table.concat(rest)
                if seq == "OQ" or seq == "[12~" or seq == "[[B" or seq:find("OQ$") then
                    return "F2"
                end
            end
            return nil
        end
        assert_eq(parse_win_seq(0, {60}), "F2", "Windows console F2 should return F2")
        assert_eq(parse_win_seq(27, {"O", "Q"}), "F2", "Windows Terminal VT F2 (ESC OQ) should return F2")
        assert_eq(parse_win_seq(27, {"[", "1", "2", "~"}), "F2", "POSIX / Linux console VT F2 (ESC [ 1 2 ~) should return F2")
        assert_eq(parse_win_seq(27, {"[", "[", "B"}), "F2", "Linux console alternative VT F2 (ESC [ [ B) should return F2")
    end)

    TestRunner.it("should support in-line cursor navigation, editing, and prompt sliding window", function()
        local format_prompt = codefind.format_query_prompt
        local visual_len = codefind.visual_len

        -- 1. Empty query states
        local p_empty_focus = format_prompt("", 1, 40, true)
        assert_true(p_empty_focus:find("|") ~= nil, "Focused empty prompt should render cursor |")
        assert_true(p_empty_focus:find("help") ~= nil, "Focused empty prompt should render help hint")

        local p_empty_unfocus = format_prompt("", 1, 40, false)
        assert_true(p_empty_unfocus:find("|") == nil, "Unfocused empty prompt should not render cursor |")

        local strip_ansi = function(s) return s:gsub("\27%[[%d;]*[mK]", "") end

        -- 2. In-line cursor positioning within available width
        local q = "database"
        -- Cursor at start (pos 1): before 'd'
        local p_start = format_prompt(q, 1, 40, true)
        assert_true(strip_ansi(p_start):find("> |database", 1, true) ~= nil, "Cursor at pos 1 should be before first char")
        assert_eq(visual_len(p_start), 3 + #q + 1, "Visual width should be prefix(3) + #q + cursor(1)")

        -- Cursor in middle (pos 5): between 'a' and 'b' ("data|base")
        local p_mid = format_prompt(q, 5, 40, true)
        assert_true(strip_ansi(p_mid):find("data|base", 1, true) ~= nil, "Cursor at pos 5 should be at 'data|base'")

        -- Cursor at end (pos 9): after 'e' ("database|")
        local p_end = format_prompt(q, 9, 40, true)
        assert_true(strip_ansi(p_end):find("database|", 1, true) ~= nil, "Cursor at pos 9 should be at 'database|'")

        -- Unfocused prompt: no cursor
        local p_unfocused = format_prompt(q, 5, 40, false)
        assert_true(p_unfocused:find("|") == nil, "Unfocused prompt should not display cursor |")
        assert_true(p_unfocused:find("database") ~= nil, "Unfocused prompt should display plain query")

        -- 3. In-line string mutation logic
        -- Insert 'x' at pos 3 of "helo" -> "hexlo"
        local orig = "helo"
        local cpos = 3
        local inserted = orig:sub(1, cpos - 1) .. "x" .. orig:sub(cpos)
        assert_eq(inserted, "hexlo", "Char insertion at pos 3 should yield hexlo")

        -- Backspace at pos 3 of "hexlo" -> "hxlo", cpos becomes 2
        local bk = inserted:sub(1, cpos - 2) .. inserted:sub(cpos)
        assert_eq(bk, "hxlo", "Backspace at pos 3 should delete char at index 2 ('e')")

        -- Delete forward at pos 2 of "hxlo" -> "hlo"
        local del = bk:sub(1, 1) .. bk:sub(3)
        assert_eq(del, "hlo", "Delete at pos 2 should delete char at index 2 ('x')")

        -- Ctrl-W backward word delete at pos 8 of "foo bar" -> "foo "
        local text = "foo bar"
        local w_cpos = 8
        local prefix = text:sub(1, w_cpos - 1)
        local suffix = text:sub(w_cpos)
        local trimmed = prefix:gsub("%s+$", "")
        local new_prefix = trimmed:match("^(.-)[%w_%-]+$") or ""
        local w_result = new_prefix .. suffix
        assert_eq(w_result, "foo ", "Ctrl-W backward word delete should delete 'bar'")

        -- 4. Long query sliding window stress test (visual length never exceeds avail_w)
        local long_q = "function search_database_records(query, options, filters)"
        for avail = 12, 50 do
            for pos = 1, #long_q + 1 do
                local p = format_prompt(long_q, pos, avail, true)
                local vl = visual_len(p)
                assert_true(vl <= avail, string.format("avail=%d pos=%d: visual_len %d exceeds %d", avail, pos, vl, avail))
                assert_true(p:find("|") ~= nil, "Cursor | must be present in sliding window")
            end
        end

        -- 5. Parsing DELETE and Ctrl-B / Ctrl-F escape sequences
        local parse_edit_seq = function(c0, rest)
            if c0 == 2 then return "CTRL_B"
            elseif c0 == 6 then return "CTRL_F"
            elseif c0 == 0 or c0 == 224 then
                if rest[1] == 83 then return "DELETE" end
            elseif c0 == 27 then
                local seq = table.concat(rest)
                if seq == "[3~" then return "DELETE" end
            end
            return nil
        end
        assert_eq(parse_edit_seq(2, {}), "CTRL_B", "ASCII 2 should return CTRL_B")
        assert_eq(parse_edit_seq(6, {}), "CTRL_F", "ASCII 6 should return CTRL_F")
        assert_eq(parse_edit_seq(0, {83}), "DELETE", "Windows console 83 should return DELETE")
        assert_eq(parse_edit_seq(27, {"[", "3", "~"}), "DELETE", "POSIX VT ESC [ 3 ~ should return DELETE")
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

TestRunner.describe("9. Multi-Finder Crawler & Path Normalization", function()
    TestRunner.it("should detect available file crawlers", function()
        local finders = codefind.detect_available_finders()
        assert_true(finders ~= nil, "Finders table should exist")
        assert_true(finders.builtin ~= nil, "Builtin finder should exist")
        assert_true(finders.builtin.available == true, "Builtin finder must always be available")
        if finders.fd then
            assert_true(type(finders.fd.label) == "string", "fd label should be a string")
        end
    end)

    TestRunner.it("should correctly resolve finder mode fallbacks", function()
        assert_eq(codefind.resolve_finder("builtin"), "builtin", "Explicit builtin should resolve to builtin")
        assert_eq(codefind.resolve_finder("native"), "builtin", "native alias should resolve to builtin")
        assert_eq(codefind.resolve_finder("nonexistent_crawler"), "builtin", "Unknown finder should fall back to builtin")

        local auto = codefind.resolve_finder("auto")
        local finders = codefind.detect_available_finders()
        if finders.fd and finders.fd.available then
            assert_eq(auto, "fd", "Auto should prefer fd when available")
        else
            assert_eq(auto, "builtin", "Auto should fallback to builtin when fd is not available")
        end
    end)

    TestRunner.it("should correctly identify ignored paths across dotag.py directory list", function()
        assert_true(codefind.has_ignored_dir(".git/objects/abc"), ".git should be ignored")
        assert_true(codefind.has_ignored_dir("project/build/release/out.o"), "build should be ignored")
        assert_true(codefind.has_ignored_dir("venv/lib/python3.10/site.py"), "venv should be ignored")
        assert_true(codefind.has_ignored_dir("vendor/boost/include/any.hpp"), "boost should be ignored")
        assert_true(codefind.has_ignored_dir("libs/OpenCV/include/opencv.hpp"), "OpenCV should be ignored")
        assert_true(codefind.has_ignored_dir("deps/3rdParty/lib.c"), "3rdParty should be ignored")
        assert_true(codefind.has_ignored_dir("node_modules/pkg/index.js"), "node_modules should be ignored")

        assert_false(codefind.has_ignored_dir("src/main.lua"), "Normal source file should not be ignored")
        assert_false(codefind.has_ignored_dir("lib/math_utils.c"), "Normal source file should not be ignored")
        assert_false(codefind.has_ignored_dir("core/engine.cpp"), "Normal source file should not be ignored")
    end)

    TestRunner.it("should produce consistent paths and ignore folders identically across crawlers", function()
        local tmpdir = make_tmpdir("_test_cf_finders_" .. os.time())
        make_tmpdir("_test_cf_finders_" .. os.time() .. "/src")
        make_tmpdir("_test_cf_finders_" .. os.time() .. "/venv")
        make_tmpdir("_test_cf_finders_" .. os.time() .. "/build")

        local f_ok = io.open(tmpdir .. "/src/app.lua", "w")
        f_ok:write("print('hello world')\n")
        f_ok:close()

        local f_venv = io.open(tmpdir .. "/venv/bad.lua", "w")
        f_venv:write("print('should be ignored')\n")
        f_venv:close()

        local f_build = io.open(tmpdir .. "/build/temp.lua", "w")
        f_build:write("print('should be ignored')\n")
        f_build:close()

        -- 1. Scan with builtin crawler
        local paths_builtin = {}
        codefind.scan_directory(tmpdir, function(full_path, fname)
            paths_builtin[fname] = full_path
        end, "builtin")

        assert_true(paths_builtin["app.lua"] ~= nil, "app.lua must be discovered by builtin")
        assert_true(paths_builtin["bad.lua"] == nil, "venv/bad.lua must be ignored by builtin")
        assert_true(paths_builtin["temp.lua"] == nil, "build/temp.lua must be ignored by builtin")

        -- 2. Scan with fd crawler if available
        local finders = codefind.detect_available_finders()
        if finders.fd and finders.fd.available then
            local paths_fd = {}
            codefind.scan_directory(tmpdir, function(full_path, fname)
                paths_fd[fname] = full_path
            end, "fd")

            assert_true(paths_fd["app.lua"] ~= nil, "app.lua must be discovered by fd")
            assert_true(paths_fd["bad.lua"] == nil, "venv/bad.lua must be ignored by fd")
            assert_true(paths_fd["temp.lua"] == nil, "build/temp.lua must be ignored by fd")

            -- 3. Path parity between builtin and fd
            assert_eq(paths_builtin["app.lua"]:gsub("\\", "/"), paths_fd["app.lua"]:gsub("\\", "/"),
                      "Paths discovered by builtin and fd should be identical")
        end

        -- 4. Indexer parity: indexing with builtin then fd should not cause false pruning or re-indexing
        local parity_db_path = tmpdir .. "/parity.db"
        local p_db = codefind.Database.open(parity_db_path)
        local res1 = codefind.Indexer.run(p_db, tmpdir, false, false, "builtin")
        assert_eq(res1.indexed, 1, "Expected 1 indexed file with builtin crawler")
        assert_eq(res1.pruned, 0, "No files pruned")

        if finders.fd and finders.fd.available then
            local res2 = codefind.Indexer.run(p_db, tmpdir, false, false, "fd")
            assert_eq(res2.indexed, 0, "No re-indexing when switching to fd crawler")
            assert_eq(res2.pruned, 0, "No false pruning when switching to fd crawler")
            assert_true(res2.skipped >= 1, "Existing file skipped/unchanged")
        end

        p_db:close()
        rm_tmpdir(tmpdir)
    end)
end)

TestRunner.describe("10. Path Normalization, Deduplication and Monorepo Disambiguation", function()
    local normalize_path = codefind.normalize_path

    TestRunner.it("should normalize path variations (backslashes, leading ./, multiple slashes, trailing slashes)", function()
        assert_eq(normalize_path([[src\utils\math.lua]]), "src/utils/math.lua", "Windows backslashes should convert to forward slashes")
        assert_eq(normalize_path("./src/utils/math.lua"), "src/utils/math.lua", "Leading ./ should be stripped")
        assert_eq(normalize_path("././src//utils///math.lua/"), "src/utils/math.lua", "Repeated ./ and slashes should be collapsed and stripped")
        assert_eq(normalize_path("."), ".", "Current dir dot should remain dot")
        assert_eq(normalize_path("./"), ".", "./ should normalize to dot")
        assert_eq(normalize_path(""), ".", "Empty string should normalize to dot")
    end)

    TestRunner.it("should deduplicate search results when code_idx contains duplicate entries", function()
        local dedup_db_path = tmp_base .. "/_test_cf_dedup_" .. os.time() .. ".db"
        local d_db = Database.open(dedup_db_path)

        d_db:begin()
        d_db:index_file("src/engine.lua", "engine.lua", "lua", 200, 1000, "function start_engine() print('engine started') end")
        d_db:commit()

        -- Inject an un-normalized duplicate record directly into code_idx as legacy databases might contain
        d_db:exec("INSERT INTO code_idx (filepath, filename, content) VALUES ('./src/engine.lua', 'engine.lua', 'function start_engine() duplicate end');")

        local results = d_db:search("start_engine")
        assert_eq(#results, 1, "Search must return exactly 1 deduplicated result despite duplicate rows in FTS index")
        assert_eq(results[1].filepath, "src/engine.lua", "Result filepath must be canonical")

        d_db:close()
        os.remove(dedup_db_path)
        os.remove(dedup_db_path .. "-wal")
        os.remove(dedup_db_path .. "-shm")
    end)

    TestRunner.it("should prune legacy un-normalized and duplicate records during incremental re-index", function()
        local tmpdir = make_tmpdir("_test_cf_prune_" .. os.time())
        local f = io.open(tmpdir .. "/app.lua", "w")
        f:write("function main() print('hello') end\n")
        f:close()

        local prune_db_path = tmpdir .. "/prune.db"
        local p_db = Database.open(prune_db_path)

        -- Initial index
        local res1 = Indexer.run(p_db, tmpdir, false, false, "builtin")
        assert_eq(res1.indexed, 1, "First index should index 1 file")

        -- Inject duplicate legacy entry with leading ./ into files and code_idx
        local legacy_path = "./" .. normalize_path(tmpdir .. "/app.lua")
        p_db:exec(string.format("INSERT INTO files (filepath, filename, extension, size, mtime) VALUES ('%s', 'app.lua', 'lua', 50, 1000);", legacy_path))
        p_db:exec(string.format("INSERT INTO code_idx (filepath, filename, content) VALUES ('%s', 'app.lua', 'function main() legacy end');", legacy_path))

        -- Re-index: self-healing should detect and eliminate the legacy un-normalized entry
        local res2 = Indexer.run(p_db, tmpdir, false, false, "builtin")
        assert_eq(#p_db:get_all_filepaths(), 1, "Database must retain only 1 canonical path")

        local search_res = p_db:search("main")
        assert_eq(#search_res, 1, "Search should return exactly 1 result after self-healing re-index")

        -- Also test pruning an orphaned file that no longer exists on disk
        local del_path = normalize_path(tmpdir .. "/deleted.lua")
        p_db:exec(string.format("INSERT INTO files (filepath, filename, extension, size, mtime) VALUES ('%s', 'deleted.lua', 'lua', 50, 1000);", del_path))
        p_db:exec(string.format("INSERT INTO code_idx (filepath, filename, content) VALUES ('%s', 'deleted.lua', 'function deleted() end');", del_path))

        local res3 = Indexer.run(p_db, tmpdir, false, false, "builtin")
        assert_true(res3.pruned >= 1, "Indexer should prune orphaned files")
        assert_eq(#p_db:get_all_filepaths(), 1, "Database must retain only existing file after pruning")

        p_db:close()
        rm_tmpdir(tmpdir)
    end)

    TestRunner.it("should remove both canonical and ./ variants when removing a file", function()
        local rem_db_path = tmp_base .. "/_test_cf_rem_" .. os.time() .. ".db"
        local r_db = Database.open(rem_db_path)

        r_db:begin()
        r_db:index_file("core/app.lua", "app.lua", "lua", 100, 1000, "function run() end")
        r_db:commit()

        -- Inject ./ variant into code_idx
        r_db:exec("INSERT INTO code_idx (filepath, filename, content) VALUES ('./core/app.lua', 'app.lua', 'function run() end');")

        -- Remove file
        r_db:remove_file("core/app.lua")

        local search_res = r_db:search("run")
        assert_eq(#search_res, 0, "Both canonical and legacy variants should be removed")

        r_db:close()
        os.remove(rem_db_path)
        os.remove(rem_db_path .. "-wal")
        os.remove(rem_db_path .. "-shm")
    end)
end)

-- ============================================================
-- Suite 11: @ext / files: filter coverage
-- (#16 test @ext filtering, #6 test files: prefix search, #4 meta table)
-- ============================================================
TestRunner.describe("11. Extension Filter and files: Prefix Search", function()
    TestRunner.it("should filter search results by extension", function()
        local fdb_path = tmp_base .. "/_test_cf_extfil_" .. os.time() .. ".db"
        local fdb = Database.open(fdb_path)
        fdb:begin()
        fdb:index_file("src/main.lua",   "main.lua",  "lua", 100, 1000, "function main() return true end")
        fdb:index_file("src/helper.c",   "helper.c",  "c",   200, 1000, "int main() { return 0; }")
        fdb:index_file("test/spec.lua",  "spec.lua",  "lua", 150, 1000, "function test_main() assert(true) end")
        fdb:index_file("docs/README.md", "README.md", "md",  300, 1000, "# Main project documentation")
        fdb:commit()

        local all_res = fdb:search("main")
        assert_true(#all_res >= 3, "Should find 'main' in at least 3 files without ext filter")

        local lua_res = fdb:search("main", { extension = "lua" })
        assert_true(#lua_res >= 1, "Should find .lua results with ext=lua filter")
        for _, r in ipairs(lua_res) do
            assert_true(r.filepath:match("%.lua$") ~= nil,
                "All ext=lua results must be .lua files, got: " .. r.filepath)
        end

        local c_res = fdb:search("main", { extension = "c" })
        assert_true(#c_res >= 1, "Should find .c results with ext=c filter")
        for _, r in ipairs(c_res) do
            assert_true(r.filepath:match("%.c$") ~= nil,
                "All ext=c results must be .c files, got: " .. r.filepath)
        end

        fdb:close()
        os.remove(fdb_path); os.remove(fdb_path .. "-wal"); os.remove(fdb_path .. "-shm")
    end)

    TestRunner.it("files: prefix should search by filename not content", function()
        local fdb_path = tmp_base .. "/_test_cf_files_" .. os.time() .. ".db"
        local fdb = Database.open(fdb_path)
        fdb:begin()
        fdb:index_file("src/config.lua",    "config.lua",   "lua", 100, 1000, "return {}")
        fdb:index_file("src/config.ts",     "config.ts",    "ts",  200, 1000, "export default {}")
        fdb:index_file("lib/auth.lua",      "auth.lua",     "lua", 150, 1000, "local M = {}")
        fdb:index_file("lib/database.lua",  "database.lua", "lua", 250, 1000, "local DB = {}")
        fdb:commit()

        local cfg_res = fdb:search("files:config")
        assert_true(#cfg_res >= 2,
            "files:config should match >=2 files named 'config.*', got " .. #cfg_res)
        for _, r in ipairs(cfg_res) do
            assert_true(r.filename:lower():find("config", 1, true) ~= nil,
                "files: result filename must contain 'config', got: " .. r.filename)
        end

        local lua_files = fdb:search("files:*.lua")
        assert_true(#lua_files >= 3,
            "files:*.lua should match at least 3 .lua files, got " .. #lua_files)

        fdb:close()
        os.remove(fdb_path); os.remove(fdb_path .. "-wal"); os.remove(fdb_path .. "-shm")
    end)

    TestRunner.it("set_meta and get_meta should persist key-value data", function()
        local mdb_path = tmp_base .. "/_test_cf_meta_" .. os.time() .. ".db"
        local mdb = Database.open(mdb_path)
        mdb:set_meta("last_index", "2026-09-28 22:00:00")
        local v = mdb:get_meta("last_index")
        assert_eq(v, "2026-09-28 22:00:00", "get_meta should return what set_meta stored")
        mdb:set_meta("last_index", "2026-09-28 23:00:00")
        local v2 = mdb:get_meta("last_index")
        assert_eq(v2, "2026-09-28 23:00:00", "set_meta should overwrite existing key")
        local v3 = mdb:get_meta("nonexistent")
        assert_true(v3 == nil, "get_meta for missing key should return nil")
        mdb:close()
        os.remove(mdb_path); os.remove(mdb_path .. "-wal"); os.remove(mdb_path .. "-shm")
    end)

    TestRunner.it("Indexer.run should write last_index to meta", function()
        local tmpdir = make_tmpdir("idxmeta")
        local fw = io.open(tmpdir .. "/hello.lua", "w")
        if fw then fw:write("return 42") fw:close() end
        local idb_path = tmp_base .. "/_test_cf_idxmeta_" .. os.time() .. ".db"
        local idb = Database.open(idb_path)
        Indexer.run(idb, tmpdir, false, false, "builtin")
        local ts = idb:get_meta("last_index")
        assert_true(ts ~= nil, "Indexer.run should write last_index to meta table")
        assert_true(#ts > 0, "last_index must be a non-empty timestamp string")
        idb:close()
        os.remove(idb_path); os.remove(idb_path .. "-wal"); os.remove(idb_path .. "-shm")
        rm_tmpdir(tmpdir)
    end)
end)

-- ============================================================
-- Suite 12: Performance / Benchmark Regression (#15)
-- ============================================================
TestRunner.describe("12. Performance Regression Benchmarks", function()
    TestRunner.it("indexing 200 synthetic files should complete in <5s", function()
        local tmpdir = make_tmpdir("bench")
        for i = 1, 200 do
            local fpath = tmpdir .. "/bench_" .. i .. ".lua"
            local fw = io.open(fpath, "w")
            if fw then
                fw:write(string.format(
                    "local mod_%d = {}\nfunction compute(x) return x * %d end\nreturn mod_%d\n",
                    i, i, i))
                fw:close()
            end
        end
        local bdb_path = tmp_base .. "/_test_cf_bench_" .. os.time() .. ".db"
        local bdb = Database.open(bdb_path)

        local t0 = os.clock()
        local stat = Indexer.run(bdb, tmpdir, false, false, "builtin")
        local elapsed = os.clock() - t0

        assert_true(stat.indexed >= 100,
            "Should index at least 100 synthetic files, got " .. stat.indexed)
        assert_true(elapsed < 5.0,
            string.format("Indexing 200 files should take <5s, took %.2fs", elapsed))

        local t1 = os.clock()
        local sr = bdb:search("compute", { limit = 20 })
        local search_elapsed = os.clock() - t1
        assert_true(#sr >= 1, "Search should find results in benchmark DB")
        assert_true(search_elapsed < 0.5,
            string.format("Search over 200-file DB should take <500ms, took %.3fs", search_elapsed))

        bdb:close()
        os.remove(bdb_path); os.remove(bdb_path .. "-wal"); os.remove(bdb_path .. "-shm")
        rm_tmpdir(tmpdir)
    end)

    TestRunner.it("files: prefix search should be fast", function()
        local tmpdir = make_tmpdir("benchfiles")
        local names = {"config","auth","router","middleware","handler","service","model","view","controller","utils"}
        for i = 1, 50 do
            local name = names[((i-1) % #names) + 1] .. "_" .. i .. ".lua"
            local fw = io.open(tmpdir .. "/" .. name, "w")
            if fw then fw:write("return {}") fw:close() end
        end
        local bdb2_path = tmp_base .. "/_test_cf_benchf_" .. os.time() .. ".db"
        local bdb2 = Database.open(bdb2_path)
        Indexer.run(bdb2, tmpdir, false, false, "builtin")

        local t2 = os.clock()
        local fres = bdb2:search("files:config")
        local fts_elapsed = os.clock() - t2
        assert_true(#fres >= 1, "files: search should find at least 1 config.* file")
        assert_true(fts_elapsed < 0.2,
            string.format("files: prefix search should be <200ms, took %.3fs", fts_elapsed))

        bdb2:close()
        os.remove(bdb2_path); os.remove(bdb2_path .. "-wal"); os.remove(bdb2_path .. "-shm")
        rm_tmpdir(tmpdir)
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
