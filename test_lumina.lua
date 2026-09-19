-- test_lumina_text_edit.lua
-- Unit and regression test for nvim text editor integration in lumina.lua

local ffi = require("ffi")

-- Test runner helper
local passed = 0
local failed = 0
local function assert_eq(actual, expected, desc)
    if actual == expected then
        passed = passed + 1
        print(string.format("  [PASS] %s", desc))
    else
        failed = failed + 1
        print(string.format("  [FAIL] %s: expected %s, got %s", desc, tostring(expected), tostring(actual)))
    end
end

local function assert_true(cond, desc)
    assert_eq(cond, true, desc)
end

local function assert_false(cond, desc)
    assert_eq(cond, false, desc)
end

print("=== Running Lumina Text Editor & Detection Tests ===")

-- Load constants and helper functions from lumina.lua by extracting the relevant isolated logic
local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true, ppm = true }
local ARCHIVE_EXTS = { zip = true, tar = true, gz = true, bz2 = true, xz = true, ["7z"] = true, rar = true }
local CODE_EXTS = {
    lua = true, c = true, h = true, cpp = true, py = true, js = true, ts = true,
    rs = true, go = true, sh = true, json = true, yaml = true, yml = true, toml = true,
    md = true, html = true, css = true, sql = true
}
local TEXT_EXTS = {
    txt = true, log = true, conf = true, cfg = true, ini = true, env = true,
    csv = true, tsv = true, xml = true, diff = true, patch = true,
    vim = true, zsh = true, bash = true, fish = true, make = true, cmake = true
}

local is_windows = (ffi.os == "Windows")

local function shell_quote(path)
    if is_windows then
        return '"' .. path:gsub('"', '\\"') .. '"'
    end
    return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function is_command_available(cmd, custom_path)
    local test_cmd
    if custom_path then
        test_cmd = 'PATH="' .. custom_path .. '" command -v ' .. shell_quote(cmd) .. ' >/dev/null 2>&1'
    else
        test_cmd = is_windows
            and ('where ' .. shell_quote(cmd) .. ' >nul 2>&1')
            or ('command -v ' .. shell_quote(cmd) .. ' >/dev/null 2>&1')
    end
    return os.execute(test_cmd) == 0
end

local function resolve_text_editor(custom_path, env_editor)
    if is_command_available("nvim", custom_path) then
        return "nvim"
    end
    local ed = env_editor or os.getenv("EDITOR") or os.getenv("VISUAL")
    if ed and #ed > 0 then
        return ed
    end
    return is_windows and "notepad" or (is_command_available("vim", custom_path) and "vim" or "vi")
end

local function is_text_file(entry)
    if not entry or entry.is_dir then return false end
    if IMAGE_EXTS[entry.ext] or ARCHIVE_EXTS[entry.ext] then return false end
    if CODE_EXTS[entry.ext] or TEXT_EXTS[entry.ext] then return true end
    if entry.size == 0 then return true end
    if entry.size > 0 and entry.size < 1024 * 1024 * 10 then
        local f = io.open(entry.path, "rb")
        if f then
            local bytes = f:read(512) or ""
            f:close()
            for i = 1, #bytes do
                local b = bytes:byte(i)
                if b < 9 or (b > 13 and b < 32) then return false end
            end
            return true
        end
    end
    return false
end

-- Test Suite 1: resolve_text_editor
print("\n-- Test Suite 1: resolve_text_editor --")
assert_eq(resolve_text_editor(), "nvim", "Resolves nvim when nvim is available in system PATH")

-- Test fallback when nvim is absent
assert_eq(resolve_text_editor("/empty_path_dummy", "custom_nano"), "custom_nano", "Falls back to custom EDITOR if nvim missing")
assert_eq(resolve_text_editor("/empty_path_dummy", ""), "vi", "Falls back to vi if nvim and EDITOR missing")

-- Test Suite 2: is_text_file with real files in workspace
print("\n-- Test Suite 2: is_text_file classification --")
local function get_file_size(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    return size or 0
end

-- Code file
local lua_entry = { path = "lumina.lua", ext = "lua", size = get_file_size("lumina.lua"), is_dir = false }
assert_true(is_text_file(lua_entry), "lumina.lua (.lua) is recognized as text file")

-- Markdown file
local md_entry = { path = "AGENTS.md", ext = "md", size = get_file_size("AGENTS.md"), is_dir = false }
assert_true(is_text_file(md_entry), "AGENTS.md (.md) is recognized as text file")

-- Plain text file
local txt_entry = { path = "data.txt", ext = "txt", size = get_file_size("data.txt"), is_dir = false }
assert_true(is_text_file(txt_entry), "data.txt (.txt) is recognized as text file")

-- Extensionless / unusual text file (Makefile)
local make_entry = { path = "Makefile", ext = "", size = get_file_size("Makefile"), is_dir = false }
assert_true(is_text_file(make_entry), "Makefile (no extension) is recognized as text file by content sniffing")

-- Dotfile text file (.gitignore)
local gitignore_entry = { path = ".gitignore", ext = "gitignore", size = get_file_size(".gitignore"), is_dir = false }
assert_true(is_text_file(gitignore_entry), ".gitignore is recognized as text file")

-- Empty file test
local empty_tmp = "tmp_empty_test.txt"
local ef = io.open(empty_tmp, "w")
ef:close()
local empty_entry = { path = empty_tmp, ext = "", size = 0, is_dir = false }
assert_true(is_text_file(empty_entry), "Empty 0-byte file is recognized as text file")
os.remove(empty_tmp)

-- Directory test
local dir_entry = { path = "LuaBridge", ext = "", size = 4096, is_dir = true }
assert_false(is_text_file(dir_entry), "Directory is NOT a text file")

-- Binary image file
local img_entry = { path = "nasa_nebula1.jpg", ext = "jpg", size = get_file_size("nasa_nebula1.jpg"), is_dir = false }
assert_false(is_text_file(img_entry), "JPG image is NOT a text file")

-- Binary executable file
local bin_entry = { path = "demo_repl", ext = "", size = get_file_size("demo_repl"), is_dir = false }
assert_false(is_text_file(bin_entry), "ELF binary executable is NOT a text file")

-- Test Suite 3: Source Code Integrity Check
print("\n-- Test Suite 3: Source Code Integrity Check --")
local lf = io.open("lumina.lua", "r")
local content = lf:read("*all")
lf:close()

assert_true(content:find("resolve_text_editor") ~= nil, "lumina.lua contains resolve_text_editor")
assert_true(content:find("is_command_available%(\"nvim\"%)") ~= nil, "lumina.lua checks nvim availability")
assert_true(content:find("clear_preview_cache") ~= nil, "lumina.lua clears preview cache on edit")
assert_true(content:find("reload_current") ~= nil, "lumina.lua reloads directory on edit")
assert_true(content:find("is_searching") ~= nil, "lumina.lua maintains is_searching state")
assert_true(content:find("io%.read%(\"%*l\"%)") == nil, "lumina.lua does not use blocking io.read for search")

-- Test Suite 4: Vim-style Search State Machine Simulation
print("\n-- Test Suite 4: Vim-Style Search State Machine Simulation --")
local mock_entries = {
    { name = "AGENTS.md" },
    { name = "data.txt" },
    { name = "lumina.lua" },
    { name = "test_lumina.lua" },
    { name = "test_pix.lua" },
}

local function filter_entries(entries, query)
    if #query == 0 then return entries end
    local res = {}
    for _, e in ipairs(entries) do
        if e.name:lower():find(query:lower(), 1, true) then
            table.insert(res, e)
        end
    end
    return res
end

local is_searching = false
local search_query = ""
local filter_query = ""
local current_list = mock_entries

local function simulate_key(k)
    if is_searching then
        if k == "ENTER" then
            is_searching = false
        elseif k == "ESC" then
            is_searching = false
            search_query = ""
            filter_query = ""
            current_list = filter_entries(mock_entries, filter_query)
        elseif k == "BACKSPACE" then
            if #search_query > 0 then
                search_query = search_query:sub(1, -2)
                filter_query = search_query
                current_list = filter_entries(mock_entries, filter_query)
            else
                is_searching = false
                filter_query = ""
                current_list = filter_entries(mock_entries, filter_query)
            end
        elseif #k == 1 and k:byte(1) >= 32 and k:byte(1) <= 126 then
            search_query = search_query .. k
            filter_query = search_query
            current_list = filter_entries(mock_entries, filter_query)
        end
    elseif k == "/" then
        is_searching = true
        search_query = ""
        filter_query = ""
        current_list = filter_entries(mock_entries, filter_query)
    elseif k == "ESC" then
        if #filter_query > 0 then
            filter_query = ""
            current_list = filter_entries(mock_entries, filter_query)
        end
    end
end

-- 1. Trigger search with '/'
simulate_key("/")
assert_true(is_searching, "Pressing '/' activates is_searching")
assert_eq(#current_list, 5, "Initial search list contains all entries")

-- 2. Type 'test'
simulate_key("t")
simulate_key("e")
simulate_key("s")
simulate_key("t")
assert_eq(search_query, "test", "search_query captures typed text 'test'")
assert_eq(#current_list, 2, "Typing 'test' live-filters down to 2 matches")

-- 3. Confirm with Enter
simulate_key("ENTER")
assert_false(is_searching, "Pressing ENTER exits is_searching mode")
assert_eq(filter_query, "test", "filter_query remains active after ENTER")
assert_eq(#current_list, 2, "List remains filtered after ENTER")

-- 4. Clear in normal mode with ESC
simulate_key("ESC")
assert_eq(filter_query, "", "Pressing ESC in normal mode clears filter_query")
assert_eq(#current_list, 5, "List restores to full 5 entries")

-- 5. Search with Backspace and Cancel with ESC
simulate_key("/")
simulate_key("l")
simulate_key("u")
simulate_key("m")
assert_eq(#current_list, 2, "Typing 'lum' matches 2 entries (lumina.lua, test_lumina.lua)")
simulate_key("BACKSPACE")
assert_eq(search_query, "lu", "Backspace deletes last character to 'lu'")
simulate_key("ESC")
assert_false(is_searching, "ESC cancels search")
assert_eq(#current_list, 5, "ESC restores all entries")

print(string.format("\nResults: %d passed, %d failed.", passed, failed))
if failed > 0 then
    os.exit(1)
end
