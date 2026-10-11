#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_codefind_web.lua
-- Comprehensive Test Suite for codefind_web.lua
--------------------------------------------------------------------------------

local codefind_web = require("codefind_web")
local codefind = require("codefind")
local json = require("json")
local ffi = require("ffi")

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

print("================================================================================")
print("  Running Integration & Unit Test Suite for codefind_web.lua")
print("================================================================================")

TestRunner.describe("1. URL & HTTP Request Parser", function()
    TestRunner.it("should decode percent-encoded URLs and query strings correctly", function()
        local dec = codefind_web.url_decode("foo%20bar%2Bbaz%21")
        assert_eq(dec, "foo bar+baz!", "url_decode should handle space and symbols")
    end)

    TestRunner.it("should parse query parameters into key-value map", function()
        local params = codefind_web.parse_query_params("q=sqlite3%20test&ext=lua&limit=25")
        assert_eq(params.q, "sqlite3 test", "q parameter mismatch")
        assert_eq(params.ext, "lua", "ext parameter mismatch")
        assert_eq(params.limit, "25", "limit parameter mismatch")
    end)

    TestRunner.it("should parse full HTTP request structure", function()
        local raw = "GET /api/search?q=open&limit=5 HTTP/1.1\r\nHost: localhost:8010\r\nUser-Agent: curl\r\n\r\n"
        local req = codefind_web.parse_http_request(raw)
        assert_true(req ~= nil, "request should not be nil")
        assert_eq(req.method, "GET", "method should be GET")
        assert_eq(req.path, "/api/search", "path should be /api/search")
        assert_eq(req.params.q, "open", "param q mismatch")
        assert_eq(req.params.limit, "5", "param limit mismatch")
    end)
end)

TestRunner.describe("2. Security: Path Traversal & Sanitization", function()
    TestRunner.it("should reject parent directory traversals", function()
        assert_true(codefind_web.sanitize_path("../../etc/passwd") == nil, "Traversal with ../.. must be blocked")
        assert_true(codefind_web.sanitize_path("foo/../../../bar") == nil, "Embedded traversal must be blocked")
    end)

    TestRunner.it("should reject absolute paths", function()
        assert_true(codefind_web.sanitize_path("/etc/passwd") == nil, "Absolute path must be blocked")
        assert_true(codefind_web.sanitize_path("C:/Windows/System32") == nil, "Drive letters must be blocked")
    end)

    TestRunner.it("should allow safe relative filepaths", function()
        local clean = codefind_web.sanitize_path("codefind.lua")
        assert_eq(clean, "codefind.lua", "Clean relative file should be permitted")
        local clean2 = codefind_web.sanitize_path("./codefind_web.lua")
        assert_eq(clean2, "codefind_web.lua", "Relative dot path should be normalized")
    end)
end)

TestRunner.describe("3. Database Search & Stats APIs", function()
    local db = codefind.Database.open(".codefind.db")
    assert_true(db ~= nil, "Could not open .codefind.db")

    TestRunner.it("should execute ranked search with elapsed ms", function()
        local res = codefind_web.handle_search_api(db, { q = "sqlite3", limit = "5" })
        assert_eq(res.status, "ok", "Search API should return ok")
        assert_true(#res.results > 0, "Search results should be non-empty")
        assert_true(res.results[1].filename ~= nil, "First result should contain filename")
        assert_true(res.results[1].rank ~= nil, "First result should contain rank")
    end)

    TestRunner.it("should support inline extension filters", function()
        local res = codefind_web.handle_search_api(db, { q = "prepare @lua", limit = "5" })
        assert_eq(res.status, "ok", "Search API should succeed")
        assert_true(res.extension == "lua", "Extension filter should be detected")
        for _, item in ipairs(res.results) do
            assert_true(item.filename:match("%.lua$") ~= nil, "File must have .lua extension: " .. item.filename)
        end
    end)

    TestRunner.it("should return comprehensive index stats", function()
        local stats_res = codefind_web.handle_stats_api(db)
        assert_eq(stats_res.status, "ok", "Stats API status should be ok")
        assert_true(stats_res.stats.total_files > 0, "Stats total_files should be > 0")
        assert_true(#stats_res.stats.extensions > 0, "Stats extensions list should be non-empty")
        assert_true(stats_res.stats.total_size_formatted ~= nil, "Formatted size should exist")
    end)

    db:close()
end)

TestRunner.describe("4. File Preview & Hit Line Highlighter API", function()
    TestRunner.it("should read source file and mark hit lines matching query", function()
        local code, f_res = codefind_web.handle_file_api({ path = "codefind_web.lua", q = "CODEFIND_WEB_VERSION" })
        assert_eq(code, 200, "File API should return 200")
        assert_eq(f_res.status, "ok", "Status should be ok")
        assert_true(f_res.total_lines > 50, "Total lines should be > 50")
        assert_true(type(f_res.lines) == "table", "Lines must be table")
        assert_true(next(f_res.hit_lines) ~= nil, "Should find at least 1 hit line for query")
    end)

    TestRunner.it("should return 403 for forbidden paths", function()
        local code, f_res = codefind_web.handle_file_api({ path = "../../../etc/shadow" })
        assert_eq(code, 403, "Forbidden path should return 403")
        assert_eq(f_res.status, "error", "Status should be error")
    end)

    TestRunner.it("should return 404 for nonexistent files", function()
        local code, f_res = codefind_web.handle_file_api({ path = "non_existent_file_xyz_123.lua" })
        assert_eq(code, 404, "Nonexistent file should return 404")
    end)
end)

TestRunner.describe("5. HTML Web App Generator & Controls", function()
    TestRunner.it("should render complete HTML5 application with dark mode styling", function()
        local html = codefind_web.render_web_app({
            total_files = 675,
            total_size = "10.24 MB",
            db_path = ".codefind.db"
        })
        assert_true(html:find("<!DOCTYPE html>", 1, true) ~= nil, "Must contain <!DOCTYPE html>")
        assert_true(html:find("CodeFind Web", 1, true) ~= nil, "Must contain app title")
        assert_true(html:find("searchInput", 1, true) ~= nil, "Must contain search input")
        assert_true(html:find("codeViewerWrap", 1, true) ~= nil, "Must contain code viewer wrap")
        assert_true(html:find("/api/search", 1, true) ~= nil, "Must contain search API hook")
    end)

    TestRunner.it("should include zoom controls, match counter and expand toggles in HTML", function()
        local html = codefind_web.render_web_app({
            total_files = 100,
            total_size = "1 MB",
            db_path = ".codefind.db"
        })
        assert_true(html:find("matchNavGroup", 1, true) ~= nil, "Must contain matchNavGroup")
        assert_true(html:find("matchCounter", 1, true) ~= nil, "Must contain matchCounter")
        assert_true(html:find("zoomLabel", 1, true) ~= nil, "Must contain zoomLabel")
        assert_true(html:find("zoomChange", 1, true) ~= nil, "Must contain zoomChange function")
        assert_true(html:find("navMatch", 1, true) ~= nil, "Must contain navMatch function")
        assert_true(html:find("wrapToggleBtn", 1, true) ~= nil, "Must contain wrapToggleBtn")
        assert_true(html:find("expandToggleBtn", 1, true) ~= nil, "Must contain expandToggleBtn")
    end)
end)

print("\n================================================================================")
print(string.format("  Tests completed: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print("================================================================================")

if TestRunner.failed > 0 then
    os.exit(1)
end
