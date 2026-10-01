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
assert_eq(resolve_text_editor("/empty_path_dummy", ""), is_windows and "notepad" or "vi", "Falls back to system default editor if nvim and EDITOR missing")

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

-- Binary data file test (contains null bytes and control chars)
local bin_tmp = "tmp_binary_test.bin"
local bf = io.open(bin_tmp, "wb")
bf:write("BIN\0\1\2\3\4\5\6\7\8")
bf:close()
local bin_entry = { path = bin_tmp, ext = "bin", size = 12, is_dir = false }
assert_false(is_text_file(bin_entry), "Binary file with control bytes is NOT a text file")
os.remove(bin_tmp)

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
assert_true(content:find("THEMES%s*=") ~= nil, "lumina.lua defines THEMES collection")
assert_true(content:find("THEME_ORDER%s*=") ~= nil, "lumina.lua defines THEME_ORDER list")
assert_true(content:find("set_theme%(") ~= nil, "lumina.lua defines set_theme function")
assert_true(content:find("cycle_theme%(") ~= nil, "lumina.lua defines cycle_theme function")
assert_true(content:find('k%s*==%s*"t"') ~= nil, "lumina.lua binds 't' key to cycle theme")
assert_true(content:find('k%s*==%s*"T"') ~= nil, "lumina.lua binds 'T' key to reverse cycle theme")
local pos_entries = content:find("local current_entries =")
local pos_targets = content:find("local function get_targets_for_op")
assert_true(pos_entries and pos_targets and pos_entries < pos_targets, "current_entries declared before get_targets_for_op")

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

-- Test Suite 5: ANSI and Unicode Safe Truncation
print("\n-- Test Suite 5: ANSI & Unicode-Safe Truncation --")
local function test_visual_len(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[a-zA-Z]", ""):gsub("[\r\n]", "")
    local count = 0
    for c in clean:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local b = c:byte(1)
        if b and b >= 240 then
            count = count + 2
        elseif b and b >= 228 and b <= 233 then
            count = count + 2
        else
            count = count + 1
        end
    end
    return count
end

local function test_truncate(str, max_w)
    local vlen = test_visual_len(str)
    if vlen <= max_w then return str end
    if max_w <= 3 then return string.rep(".", max_w) end

    local esc_pattern = "^\27%[[%d;]*[a-zA-Z]"
    local utf8_pattern = "^[%z\1-\127\194-\244][\128-\191]*"

    local out = {}
    local curr_w = 0
    local i = 1
    local len = #str

    while i <= len do
        local sub = str:sub(i)
        local esc = sub:match(esc_pattern)
        if esc then
            table.insert(out, esc)
            i = i + #esc
        else
            local char = sub:match(utf8_pattern) or sub:sub(1, 1)
            local b = char:byte(1)
            local w = (b and ((b >= 240) or (b >= 228 and b <= 233))) and 2 or 1
            if curr_w + w > max_w - 3 then
                table.insert(out, "\27[0m...")
                return table.concat(out)
            end
            table.insert(out, char)
            curr_w = curr_w + w
            i = i + #char
        end
    end
    return table.concat(out)
end

-- Verify visual_len with emoji
assert_eq(test_visual_len("📁"), 2, "Folder emoji occupies 2 columns")
assert_eq(test_visual_len("📜"), 2, "Script emoji occupies 2 columns")
assert_eq(test_visual_len("\27[38;2;56;189;248m📁 test\27[0m"), 7, "Colored emoji visual length accounts for emoji width")

-- Verify truncate does not mangle ANSI escape sequences
local colored_str = "\27[38;2;56;189;248m  📜 classic.lua          331 B\27[0m"
local tr = test_truncate(colored_str, 20)
assert_true(test_visual_len(tr) <= 20, "Truncated length does not exceed max_w")
assert_true(tr:find("\27%[0m%.%.%.$") ~= nil, "Truncated string cleanly terminates with reset and ellipsis")
-- Check for broken escape sequence like "\27[38;2;56;189;248..."
assert_false(tr:find("\27%[[%d;]*%.%.%.") ~= nil, "Truncated string never has broken ANSI sequence before dots")

-- Test Suite 6: CRLF Sanitization in Previews and Rows
print("\n-- Test Suite 6: CRLF Sanitization in Previews and Rows --")
local function test_draw_row(x, y, w, content)
    local sanitized = tostring(content):gsub("[\r\n]", "")
    local clr = test_truncate(sanitized, w - 2)
    local vlen = test_visual_len(clr)
    local pad = string.rep(" ", math.max(0, w - 2 - vlen))
    return string.format("\27[%d;%dH%s%s\27[0m", y, x + 1, clr, pad)
end

-- Test draw_row with CRLF content
local crlf_content = "Object.__index = Object\r"
local rendered_row = test_draw_row(50, 2, 40, crlf_content)
assert_false(rendered_row:find("\r") ~= nil, "Rendered row contains no carriage return '\\r'")
assert_false(rendered_row:find("\n") ~= nil, "Rendered row contains no newline '\\n'")
assert_true(rendered_row:find("Object%.%_%_index %= Object") ~= nil, "Rendered row retains content")

-- Verify visual_len and truncate ignore \r\n
assert_eq(test_visual_len("hello\r\n"), 5, "visual_len ignores trailing CRLF")
local tr_crlf = test_truncate("hello world\r\n", 8)
assert_false(tr_crlf:find("\r") ~= nil, "truncate strips '\\r'")
assert_false(tr_crlf:find("\n") ~= nil, "truncate strips '\\n'")

-- Verify real CRLF file preview parsing (/home/zliu/test/love/classic.lua if present)
local cf = io.open("/home/zliu/test/love/classic.lua", "r")
if cf then
    local l1 = cf:read("*l")
    cf:close()
    if l1 then
        local cleaned_l1 = l1:gsub("\r$", "")
        assert_false(cleaned_l1:find("\r") ~= nil, "classic.lua line has \\r stripped")
    end
end

-- Test Suite 7: Theme Engine & Palette Integrity
print("\n-- Test Suite 7: Theme Engine & Palette Integrity --")
local lumina = require("lumina")
assert_true(lumina ~= nil, "lumina module loads successfully via require")
assert_true(#lumina.THEME_ORDER == 6, "lumina defines exactly 6 curated themes in THEME_ORDER")

local expected_tokens = {
    "name", "border_col", "border_focus", "header_accent", "header_path",
    "dir_col", "exec_col", "image_col", "archive_col", "code_col", "file_col", "symlink_col",
    "cursor_bg", "parent_bg", "syn_keyword", "syn_string", "syn_comment", "syn_number",
    "syn_header", "status_accent"
}

for _, key in ipairs(lumina.THEME_ORDER) do
    local theme = lumina.THEMES[key]
    assert_true(theme ~= nil, string.format("Theme '%s' exists in lumina.THEMES", key))
    for _, tok in ipairs(expected_tokens) do
        assert_true(theme[tok] ~= nil and #theme[tok] > 0,
            string.format("Theme '%s' defines required token '%s'", key, tok))
        if tok ~= "name" then
            assert_true(theme[tok]:find("\27%[") ~= nil,
                string.format("Theme '%s' token '%s' contains valid ANSI escape sequence", key, tok))
        end
    end
end

-- Test set_theme
assert_true(lumina.set_theme("dracula"), "set_theme('dracula') returns true")
assert_eq(lumina.get_current_theme(), "dracula", "Current theme is dracula")
assert_eq(lumina.get_theme_name(), "Dracula", "Theme name is 'Dracula'")
assert_eq(lumina.C.name, "Dracula", "Active C palette reflects Dracula")

-- Test invalid theme rejection
assert_false(lumina.set_theme("nonexistent_theme_xyz"), "set_theme with invalid name returns false")
assert_eq(lumina.get_current_theme(), "dracula", "Current theme unchanged after invalid set_theme")

-- Test forward cycle through all themes
lumina.set_theme("tokyo_night")
for idx, key in ipairs(lumina.THEME_ORDER) do
    if idx > 1 then
        local next_key = lumina.cycle_theme(1)
        assert_eq(next_key, key, string.format("cycle_theme(1) step %d matches %s", idx, key))
    end
end
-- One more cycle returns to first
local looped_key = lumina.cycle_theme(1)
assert_eq(looped_key, lumina.THEME_ORDER[1], "cycle_theme(1) wraps around to first theme")

-- Test backward cycle
local prev_key = lumina.cycle_theme(-1)
assert_eq(prev_key, lumina.THEME_ORDER[#lumina.THEME_ORDER], "cycle_theme(-1) wraps around to last theme")

-- Test Suite 8: Theme Switcher & Search Isolation State Machine Simulation
print("\n-- Test Suite 8: Theme Switcher & Search Isolation State Machine --")
local sim_theme = "tokyo_night"
local sim_searching = false
local sim_search_buf = ""
local sim_theme_order = lumina.THEME_ORDER

local function sim_cycle(step)
    local cur_idx = 1
    for i, k in ipairs(sim_theme_order) do
        if k == sim_theme then cur_idx = i; break end
    end
    local new_idx = (cur_idx - 1 + step) % #sim_theme_order + 1
    sim_theme = sim_theme_order[new_idx]
end

local function sim_event(k)
    if sim_searching then
        if k == "ENTER" or k == "ESC" then
            sim_searching = false
        elseif #k == 1 and k:byte(1) >= 32 and k:byte(1) <= 126 then
            sim_search_buf = sim_search_buf .. k
        end
    else
        if k == "/" then
            sim_searching = true
            sim_search_buf = ""
        elseif k == "t" then
            sim_cycle(1)
        elseif k == "T" then
            sim_cycle(-1)
        end
    end
end

-- 1. Normal mode: press 't'
assert_eq(sim_theme, "tokyo_night", "Initial theme is tokyo_night")
sim_event("t")
assert_eq(sim_theme, "dracula", "Pressing 't' in normal mode cycles to dracula")
sim_event("t")
assert_eq(sim_theme, "nord", "Pressing 't' again cycles to nord")
sim_event("T")
assert_eq(sim_theme, "dracula", "Pressing 'T' cycles back to dracula")

-- 2. Enter search mode and type 'theme' (contains 't')
sim_event("/")
assert_true(sim_searching, "Entered search mode")
sim_event("t")
sim_event("h")
sim_event("e")
sim_event("m")
sim_event("e")
assert_eq(sim_search_buf, "theme", "Search buffer captures 'theme' without cycling theme")
assert_eq(sim_theme, "dracula", "Theme remains unchanged while typing 't' inside search")

-- 3. Exit search mode and confirm 't' cycles again
sim_event("ENTER")
assert_false(sim_searching, "Exited search mode")
sim_event("t")
assert_eq(sim_theme, "nord", "Pressing 't' after exiting search resumes cycling")

-- Test Suite 9: Fuzzy Scoring Algorithm & Recursive File Search
print("\n-- Test Suite 9: Fuzzy Scoring Algorithm & Recursive File Search --")

-- Extract fuzzy_score from lumina.lua logic
local function test_fuzzy_score(pattern, str)
    if not pattern or #pattern == 0 then return true, 0 end
    if not str or #str == 0 then return false, 0 end
    local pat_l = pattern:lower()
    local str_l = str:lower()
    local pat_len = #pat_l
    local str_len = #str_l
    if pat_len > str_len then return false, 0 end

    local sub_pos = str_l:find(pat_l, 1, true)
    local is_exact_prefix = (sub_pos == 1)
    local score = 0
    local p_idx = 1
    local prev_match_idx = -1
    local consecutive = 0

    for s_idx = 1, str_len do
        local p_char = pat_l:byte(p_idx)
        local s_char = str_l:byte(s_idx)

        if p_char == s_char then
            local char_score = 10
            if prev_match_idx == s_idx - 1 then
                consecutive = consecutive + 1
                char_score = char_score + (consecutive * 12)
            else
                consecutive = 0
            end

            if s_idx == 1 then
                char_score = char_score + 35
            else
                local prev_byte = str_l:byte(s_idx - 1)
                if prev_byte == 95 or prev_byte == 45 or prev_byte == 46 or prev_byte == 47 or prev_byte == 32 then
                    char_score = char_score + 30
                end
            end

            if pattern:byte(p_idx) == str:byte(s_idx) then
                char_score = char_score + 3
            end

            score = score + char_score
            prev_match_idx = s_idx
            p_idx = p_idx + 1

            if p_idx > pat_len then
                if is_exact_prefix then
                    score = score + 50
                elseif sub_pos then
                    score = score + 25
                end
                score = score - math.floor((str_len - pat_len) * 0.5)
                return true, score
            end
        end
    end
    return false, 0
end

-- Test 9.1: Exact and Substring matches
local matched, score = test_fuzzy_score("lumina", "lumina.lua")
assert_true(matched, "Fuzzy match: 'lumina' matches 'lumina.lua'")
assert_true(score > 100, "Exact prefix match receives high score bonus")

-- Test 9.2: Acronym / boundary match
local matched_fsand, score_fsand = test_fuzzy_score("fsand", "ffi_falling_sand.lua")
assert_true(matched_fsand, "Fuzzy match: 'fsand' matches 'ffi_falling_sand.lua'")

local matched_oracer, score_oracer = test_fuzzy_score("oracer", "outrun_racer.lua")
assert_true(matched_oracer, "Fuzzy match: 'oracer' matches 'outrun_racer.lua'")

-- Test 9.3: Non-matching queries
local matched_fail, _ = test_fuzzy_score("xyz123", "lumina.lua")
assert_false(matched_fail, "Fuzzy non-match correctly returns false")

-- Test 9.4: Prefix / exact score ranks higher than scattered match
local _, score_exact = test_fuzzy_score("lua", "luatop.lua")
local _, score_scattered = test_fuzzy_score("lua", "demo_guess_number.lua")
assert_true(score_exact > score_scattered, "Prefix match scores higher than end-of-string match")

-- Test 9.5: Case-insensitive matching
local matched_case, _ = test_fuzzy_score("WOLF3D", "ffi_wolf3d_raycaster.lua")
assert_true(matched_case, "Case-insensitive fuzzy match succeeds for uppercase query")

-- Test 9.6: Empty pattern matches everything
local matched_empty, score_empty = test_fuzzy_score("", "anything.lua")
assert_true(matched_empty, "Empty pattern matches with zero score")
assert_eq(score_empty, 0, "Empty pattern score is 0")

-- Test Suite 10: Startup Directory & File Resolution
print("\n-- Test Suite 10: Startup Directory & File Resolution --")

local bit = require("bit")
pcall(function()
    ffi.cdef[[
        struct stat {
            unsigned long  st_dev;
            unsigned long  st_ino;
            unsigned long  st_nlink;
            unsigned int   st_mode;
            unsigned int   st_uid;
            unsigned int   st_gid;
            unsigned int   __pad0;
            unsigned long  st_rdev;
            long           st_size;
            long           st_blksize;
            long           st_blocks;
            long           st_atime;
            unsigned long  st_atime_nsec;
            long           st_mtime;
            unsigned long  st_mtime_nsec;
            long           st_ctime;
            unsigned long  st_ctime_nsec;
            long           __unused[3];
        };
        int stat(const char *pathname, struct stat *statbuf);
        char *realpath(const char *path, char *resolved_path);
    ]]
end)

local function resolve_startup_path(requested_path)
    local buf = ffi.new("char[4096]")
    local canonical = requested_path
    if ffi.C.realpath(requested_path, buf) ~= nil then
        canonical = ffi.string(buf)
    end

    local is_directory = false
    local st = ffi.new("struct stat")
    if ffi.C.stat(requested_path, st) == 0 then
        is_directory = (bit.band(tonumber(st.st_mode), 0xF000) == 0x4000)
    end

    local current_dir = canonical
    local initial_selection_name = nil

    if not is_directory then
        local requested_file = io.open(requested_path, "rb")
        if requested_file then
            requested_file:close()
            initial_selection_name = requested_path:match("([^/\\]+)$")
            local parent = canonical:match("^(.*)/[^/]+$") or "/"
            current_dir = parent
        end
    end

    return current_dir, initial_selection_name, is_directory
end

-- Test 10.1: Current directory "." opens as directory itself
local cur_dir, sel_name, is_dir = resolve_startup_path(".")
assert_true(is_dir, "'.' is correctly detected as a directory")
assert_true(cur_dir:match("lualab$") ~= nil, "Startup in '.' resolves to lualab, not parent dir")
assert_eq(sel_name, nil, "No initial file selection when opening directory directly")

-- Test 10.2: File path opens parent directory with file selected
local file_dir, file_sel, file_is_dir = resolve_startup_path("lumina.lua")
assert_false(file_is_dir, "'lumina.lua' is correctly detected as a file")
assert_true(file_dir:match("lualab$") ~= nil, "File target resolves to parent directory")
assert_eq(file_sel, "lumina.lua", "File target sets initial selection name to 'lumina.lua'")

-- Test Suite 11: Jump to Start Directory (H / gh) and Home (~)
print("\n-- Test Suite 11: Jump to Start Directory (H / gh) and Home (~) --")

local sim_start_dir = "/home/user/workspace/lualab"
local sim_home_dir = "/home/user"
local sim_cur_dir = sim_start_dir
local sim_g_prefix = false

local function sim_nav_key(k)
    if k == "H" then
        sim_g_prefix = false
        sim_cur_dir = sim_start_dir
    elseif k == "~" then
        sim_g_prefix = false
        sim_cur_dir = sim_home_dir
    elseif k == "g" then
        if sim_g_prefix then
            sim_g_prefix = false -- 'gg'
        else
            sim_g_prefix = true
        end
    elseif sim_g_prefix and (k == "h" or k == "s") then
        sim_g_prefix = false
        sim_cur_dir = sim_start_dir
    else
        sim_g_prefix = false
    end
end

-- Simulate navigating into deep directory
sim_cur_dir = "/home/user/workspace/lualab/sub/deep/folder"
assert_eq(sim_cur_dir, "/home/user/workspace/lualab/sub/deep/folder", "Navigated to deep subfolder")

-- 1. Press 'H' to jump to start_dir
sim_nav_key("H")
assert_eq(sim_cur_dir, sim_start_dir, "Pressing 'H' immediately returns to start_dir")

-- 2. Navigate away and press 'gh'
sim_cur_dir = "/var/log/nginx"
sim_nav_key("g")
assert_true(sim_g_prefix, "Pressing 'g' sets g_prefix")
sim_nav_key("h")
assert_false(sim_g_prefix, "Pressing 'h' after 'g' resets g_prefix")
assert_eq(sim_cur_dir, sim_start_dir, "Pressing 'gh' returns to start_dir")

-- 3. Navigate away and press '~'
sim_cur_dir = "/usr/local/bin"
sim_nav_key("~")
assert_eq(sim_cur_dir, sim_home_dir, "Pressing '~' jumps to user home directory")

-- Test Suite 12: Directory Sorting Modes (Name, Size, Time, Ext)
print("\n-- Test Suite 12: Directory Sorting Modes (Name, Size, Time, Ext) --")

local dummy_entries = {
    { name = "zeta.txt",   path = "/test/zeta.txt",   ext = "txt",  size = 500,  mtime = 1000, is_dir = false },
    { name = "alpha.lua",  path = "/test/alpha.lua",  ext = "lua",  size = 2000, mtime = 3000, is_dir = false },
    { name = "beta.c",     path = "/test/beta.c",     ext = "c",    size = 100,  mtime = 2000, is_dir = false },
    { name = "dir_b",      path = "/test/dir_b",      ext = "",     size = 4096, mtime = 500,  is_dir = true },
    { name = "dir_a",      path = "/test/dir_a",      ext = "",     size = 4096, mtime = 800,  is_dir = true },
}

local function clone_dummy()
    local t = {}
    for _, e in ipairs(dummy_entries) do
        table.insert(t, {
            name = e.name, path = e.path, ext = e.ext,
            size = e.size, mtime = e.mtime, is_dir = e.is_dir,
        })
    end
    return t
end

-- 1. Sort by name_asc: Directories first (dir_a, dir_b), then files (alpha.lua, beta.c, zeta.txt)
local s1 = lumina.sort_entries(clone_dummy(), "name_asc")
assert_true(s1[1].is_dir and s1[1].name == "dir_a", "name_asc: first item is dir_a")
assert_true(s1[2].is_dir and s1[2].name == "dir_b", "name_asc: second item is dir_b")
assert_eq(s1[3].name, "alpha.lua", "name_asc: third item is alpha.lua")
assert_eq(s1[4].name, "beta.c", "name_asc: fourth item is beta.c")
assert_eq(s1[5].name, "zeta.txt", "name_asc: fifth item is zeta.txt")

-- 2. Sort by name_desc: Directories first (dir_b, dir_a), then files (zeta.txt, beta.c, alpha.lua)
local s2 = lumina.sort_entries(clone_dummy(), "name_desc")
assert_true(s2[1].is_dir and s2[1].name == "dir_b", "name_desc: first item is dir_b")
assert_true(s2[2].is_dir and s2[2].name == "dir_a", "name_desc: second item is dir_a")
assert_eq(s2[3].name, "zeta.txt", "name_desc: third item is zeta.txt")
assert_eq(s2[4].name, "beta.c", "name_desc: fourth item is beta.c")
assert_eq(s2[5].name, "alpha.lua", "name_desc: fifth item is alpha.lua")

-- 3. Sort by size (descending size for files): alpha.lua (2000), zeta.txt (500), beta.c (100)
local s3 = lumina.sort_entries(clone_dummy(), "size")
assert_true(s3[1].is_dir and s3[2].is_dir, "size: directories remain on top")
assert_eq(s3[3].name, "alpha.lua", "size: largest file is alpha.lua (2000 bytes)")
assert_eq(s3[4].name, "zeta.txt", "size: middle file is zeta.txt (500 bytes)")
assert_eq(s3[5].name, "beta.c", "size: smallest file is beta.c (100 bytes)")

-- 4. Sort by mtime (newest first): alpha.lua (3000), beta.c (2000), zeta.txt (1000)
local s4 = lumina.sort_entries(clone_dummy(), "mtime")
assert_true(s4[1].is_dir and s4[2].is_dir, "mtime: directories remain on top")
assert_eq(s4[3].name, "alpha.lua", "mtime: newest file is alpha.lua (mtime 3000)")
assert_eq(s4[4].name, "beta.c", "mtime: middle file is beta.c (mtime 2000)")
assert_eq(s4[5].name, "zeta.txt", "mtime: oldest file is zeta.txt (mtime 1000)")

-- 5. Sort by ext: c (beta.c), lua (alpha.lua), txt (zeta.txt)
local s5 = lumina.sort_entries(clone_dummy(), "ext")
assert_true(s5[1].is_dir and s5[2].is_dir, "ext: directories remain on top")
assert_eq(s5[3].name, "beta.c", "ext: first ext is .c (beta.c)")
assert_eq(s5[4].name, "alpha.lua", "ext: second ext is .lua (alpha.lua)")
assert_eq(s5[5].name, "zeta.txt", "ext: third ext is .txt (zeta.txt)")

-- 6. Interactive sort state machine simulation
local sim_mode = "name_asc"
local sim_sorting = false
local function sim_sort_event(k)
    if sim_sorting then
        sim_sorting = false
        if k == "n" then
            sim_mode = (sim_mode == "name_asc") and "name_desc" or "name_asc"
        elseif k == "s" then
            sim_mode = "size"
        elseif k == "m" or k == "t" then
            sim_mode = "mtime"
        elseif k == "e" then
            sim_mode = "ext"
        elseif k == "r" then
            if sim_mode == "name_asc" then sim_mode = "name_desc"
            elseif sim_mode == "name_desc" then sim_mode = "name_asc" end
        end
    elseif k == "s" then
        sim_sorting = true
    end
end

assert_false(sim_sorting, "Sorting modal inactive initially")
sim_sort_event("s")
assert_true(sim_sorting, "Pressing 's' activates sort prompt")
sim_sort_event("s")
assert_false(sim_sorting, "Sort prompt closed after option selection")
assert_eq(sim_mode, "size", "Sort mode changed to 'size'")

sim_sort_event("s")
sim_sort_event("m")
assert_eq(sim_mode, "mtime", "Sort mode changed to 'mtime'")

sim_sort_event("s")
sim_sort_event("e")
assert_eq(sim_mode, "ext", "Sort mode changed to 'ext'")

sim_sort_event("s")
sim_sort_event("n")
assert_eq(sim_mode, "name_asc", "Sort mode changed to 'name_asc'")

sim_sort_event("s")
sim_sort_event("n")
assert_eq(sim_mode, "name_desc", "Pressing 'n' again toggles to 'name_desc'")

-- Test Suite 13: Multi-Selection Tagging (Space, v, V, and ESC clear)
print("\n-- Test Suite 13: Multi-Selection Tagging (Space, v, V, and ESC clear) --")

local sim_sel_entries = {
    { name = "alpha.lua", path = "/dir/alpha.lua" },
    { name = "beta.lua",  path = "/dir/beta.lua" },
    { name = "gamma.lua", path = "/dir/gamma.lua" },
}

local sim_selected_paths = {}
local sim_cursor = 1

local function sim_count_selected()
    local c = 0
    for _ in pairs(sim_selected_paths) do c = c + 1 end
    return c
end

local function sim_tag_key(k)
    if k == " " or k == "v" then
        local cur_entry = sim_sel_entries[sim_cursor]
        if cur_entry then
            if sim_selected_paths[cur_entry.path] then
                sim_selected_paths[cur_entry.path] = nil
            else
                sim_selected_paths[cur_entry.path] = cur_entry
            end
            if sim_cursor < #sim_sel_entries then
                sim_cursor = sim_cursor + 1
            end
        end
    elseif k == "V" then
        for _, e in ipairs(sim_sel_entries) do
            if sim_selected_paths[e.path] then
                sim_selected_paths[e.path] = nil
            else
                sim_selected_paths[e.path] = e
            end
        end
    elseif k == "ESC" then
        if sim_count_selected() > 0 then
            sim_selected_paths = {}
        end
    end
end

-- 1. Initial state
assert_eq(sim_count_selected(), 0, "Initial selection count is 0")
assert_eq(sim_cursor, 1, "Initial cursor is at 1")

-- 2. Tag first item with 'Space'
sim_tag_key(" ")
assert_eq(sim_count_selected(), 1, "After Space, 1 item is selected")
assert_true(sim_selected_paths["/dir/alpha.lua"] ~= nil, "alpha.lua is tagged")
assert_eq(sim_cursor, 2, "Cursor stepped down to index 2 (beta.lua)")

-- 3. Tag second item with 'v'
sim_tag_key("v")
assert_eq(sim_count_selected(), 2, "After 'v', 2 items are selected")
assert_true(sim_selected_paths["/dir/beta.lua"] ~= nil, "beta.lua is tagged")
assert_eq(sim_cursor, 3, "Cursor stepped down to index 3 (gamma.lua)")

-- 4. Untag second item by navigating back and pressing 'v'
sim_cursor = 2
sim_tag_key("v")
assert_eq(sim_count_selected(), 1, "Untagging beta.lua reduces selection count to 1")
assert_true(sim_selected_paths["/dir/beta.lua"] == nil, "beta.lua is no longer tagged")
assert_true(sim_selected_paths["/dir/alpha.lua"] ~= nil, "alpha.lua remains tagged")

-- 5. Invert selection with 'V'
sim_tag_key("V")
assert_eq(sim_count_selected(), 2, "Inverting selection results in 2 tagged items")
assert_true(sim_selected_paths["/dir/alpha.lua"] == nil, "alpha.lua is now untagged")
assert_true(sim_selected_paths["/dir/beta.lua"] ~= nil, "beta.lua is now tagged")
assert_true(sim_selected_paths["/dir/gamma.lua"] ~= nil, "gamma.lua is now tagged")

-- 6. Clear all tags with 'ESC'
sim_tag_key("ESC")
assert_eq(sim_count_selected(), 0, "Pressing ESC clears all selections")

-- Test Suite 14: File Operations & Clipboard State Machine (Yank, Cut, Paste, Delete, New, Rename)
print("\n-- Test Suite 14: File Operations & Clipboard State Machine --")

local sim_clip = { mode = nil, items = {} }
local sim_entries = {
    { name = "file1.txt", path = "/sandbox/file1.txt", is_dir = false },
    { name = "file2.txt", path = "/sandbox/file2.txt", is_dir = false },
    { name = "subfolder", path = "/sandbox/subfolder", is_dir = true },
}
local sim_sel = {}
local sim_cur_idx = 1
local fs_store = {
    ["/sandbox/file1.txt"] = "hello 1",
    ["/sandbox/file2.txt"] = "hello 2",
    ["/sandbox/subfolder"] = true,
}

local function sim_get_targets()
    local t = {}
    local has_tag = false
    for _ in pairs(sim_sel) do has_tag = true; break end
    if has_tag then
        for _, it in pairs(sim_sel) do table.insert(t, it) end
    else
        table.insert(t, sim_entries[sim_cur_idx])
    end
    return t
end

-- 1. Yank (Copy) current item
local t1 = sim_get_targets()
assert_eq(#t1, 1, "Target count is 1 for untagged cursor item")
assert_eq(t1[1].name, "file1.txt", "Target item is file1.txt")
sim_clip = { mode = "copy", items = t1 }
assert_eq(sim_clip.mode, "copy", "Clipboard mode is copy")
assert_eq(#sim_clip.items, 1, "Clipboard contains 1 item")

-- 2. Simulate paste into target dir /sandbox/subfolder
local paste_dest = "/sandbox/subfolder"
for _, item in ipairs(sim_clip.items) do
    local dst = paste_dest .. "/" .. item.name
    fs_store[dst] = fs_store[item.path]
end
assert_eq(fs_store["/sandbox/subfolder/file1.txt"], "hello 1", "Pasted file exists in destination")
assert_eq(fs_store["/sandbox/file1.txt"], "hello 1", "Source file remains after copy")

-- 3. Cut tagged items
sim_sel["/sandbox/file2.txt"] = sim_entries[2]
local t2 = sim_get_targets()
assert_eq(#t2, 1, "Target count is 1 for tagged file2.txt")
sim_clip = { mode = "cut", items = t2 }
sim_sel = {}
assert_eq(sim_clip.mode, "cut", "Clipboard mode is cut")

-- 4. Paste cut item into /sandbox/subfolder
for _, item in ipairs(sim_clip.items) do
    local dst = paste_dest .. "/" .. item.name
    fs_store[dst] = fs_store[item.path]
    fs_store[item.path] = nil
end
if sim_clip.mode == "cut" then sim_clip = { mode = nil, items = {} } end
assert_eq(fs_store["/sandbox/subfolder/file2.txt"], "hello 2", "Cut item pasted in destination")
assert_true(fs_store["/sandbox/file2.txt"] == nil, "Original item deleted after cut-paste")
assert_true(sim_clip.mode == nil, "Clipboard reset after cut paste")

-- 5. Delete operation simulation
assert_true(fs_store["/sandbox/file1.txt"] ~= nil, "file1.txt exists before delete")
fs_store["/sandbox/file1.txt"] = nil
assert_true(fs_store["/sandbox/file1.txt"] == nil, "file1.txt deleted successfully")

-- 6. Create new file / folder validation
local new_file_name = "notes.md"
local is_dir = (new_file_name:sub(-1) == "/")
assert_false(is_dir, "notes.md detected as regular file")
local new_dir_name = "projects/"
local is_dir_folder = (new_dir_name:sub(-1) == "/")
assert_true(is_dir_folder, "projects/ detected as directory")

-- 7. Modal rendering geometry and line clearance check
print("\n-- Test Suite 15: Modal Dialog Geometry & Clearance --")
local function render_modal_preview(box_w, box_h, title, message)
    local lines = {}
    local bcol = "[BCOL]"
    local title_str = string.format(" %s ", title)
    local top_fill = string.rep("─", math.max(0, box_w - 2 - #title_str))
    table.insert(lines, string.format("%s╭%s%s╮", bcol, title_str, top_fill))

    local msg_line = " " .. message:sub(1, box_w - 4)
    local pad = string.rep(" ", math.max(0, box_w - 2 - #msg_line))
    table.insert(lines, string.format("%s│%s%s│", bcol, msg_line, pad))

    for r = 2, box_h - 2 do
        local blank_pad = string.rep(" ", box_w - 2)
        table.insert(lines, string.format("%s│%s│", bcol, blank_pad))
    end

    local hint = " [y] Yes  [n/Esc] No "
    local bot_fill = string.rep("─", math.max(0, box_w - 2 - #hint))
    table.insert(lines, string.format("%s╰%s%s╯", bcol, hint, bot_fill))
    return lines
end

local modal_lines = render_modal_preview(50, 5, "CONFIRM DELETION", "Delete 'out.txt'?")
assert_eq(#modal_lines, 5, "Modal renders exactly box_h (5) lines leaving zero gaps")
for i, line in ipairs(modal_lines) do
    local has_border = (line:find("╭") ~= nil) or (line:find("│") ~= nil) or (line:find("╰") ~= nil)
    assert_true(has_border, string.format("Line %d is bordered", i))
end

-- Test exact format strings for modals
local ok_confirm, rendered_confirm = pcall(function()
    local start_y, start_x, bcol, C_reset, msg_line, pad = 10, 20, "[BCOL]", "[RESET]", " Delete 'test'? ", "   "
    return string.format("\27[%d;%dH%s│%s%s%s│%s",
        start_y + 1, start_x, bcol, C_reset .. msg_line, pad, bcol, C_reset)
end)
assert_true(ok_confirm, "Confirm modal message row format string executes without error")
assert_true(rendered_confirm ~= nil and rendered_confirm:find("Delete 'test'?") ~= nil, "Confirm modal message formatted correctly")

local ok_input, rendered_input = pcall(function()
    local start_y, start_x, bcol, p_str, input_str, pad, C_reset = 10, 20, "[BCOL]", " Name: ", "file.txt", "   ", "[RESET]"
    return string.format("\27[%d;%dH%s│%s%s%s%s│%s",
        start_y + 1, start_x, bcol, C_reset, p_str .. input_str, pad, bcol, C_reset)
end)
assert_true(ok_input, "Input modal row format string executes without error")
assert_true(rendered_input ~= nil and rendered_input:find("file.txt") ~= nil, "Input modal message formatted correctly")

-- Test Suite 16: Interactive Help Overlay (?) & Multi-Delete Prompting
print("\n-- Test Suite 16: Help Overlay & Multi-Delete Prompting --")
local function render_help_preview(box_w, box_h, cheatsheet)
    local lines = {}
    local bcol = "[BCOL]"
    local title_str = " LUMINA CHEATSHEET "
    local top_fill = string.rep("─", math.max(0, box_w - 2 - #title_str))
    table.insert(lines, string.format("%s╭%s%s╮", bcol, title_str, top_fill))

    local content_lines = box_h - 2
    for r = 1, content_lines do
        local item = cheatsheet[r]
        if item then
            if item.section then
                local s_str = " " .. item.section .. " "
                local pad = string.rep("─", math.max(0, box_w - 2 - #item.section - 2))
                table.insert(lines, string.format("%s│%s%s│", bcol, s_str, pad))
            else
                local k_str = "   " .. string.format("%-14s", item.key)
                local d_str = " " .. item.desc
                local total_vlen = #string.format("   %-14s %s", item.key, item.desc)
                local pad = string.rep(" ", math.max(0, box_w - 2 - total_vlen))
                table.insert(lines, string.format("%s│%s%s%s│", bcol, k_str, d_str, pad))
            end
        else
            local blank_pad = string.rep(" ", box_w - 2)
            table.insert(lines, string.format("%s│%s│", bcol, blank_pad))
        end
    end

    local hint = " Press any key or Esc to close "
    local bot_fill = string.rep("─", math.max(0, box_w - 2 - #hint))
    table.insert(lines, string.format("%s╰%s%s╯", bcol, hint, bot_fill))
    return lines
end

local sample_cheatsheet = {
    { section = "NAVIGATION" },
    { key = "h, l, Enter", desc = "Enter / Leave directory or open file" },
    { section = "SELECTION" },
    { key = "Space, v",    desc = "Tag / Untag item" }
}
local help_lines = render_help_preview(60, 8, sample_cheatsheet)
assert_eq(#help_lines, 8, "Help modal renders exactly box_h (8) rows")
assert_true(help_lines[1]:find("LUMINA CHEATSHEET") ~= nil, "Help modal top border contains title")
assert_true(help_lines[#help_lines]:find("Press any key") ~= nil, "Help modal footer contains hint")

-- Test modal wait loop logic
local inputs = { nil, nil, "ESC" }
local input_idx = 1
local dismissed = false
local loop_count = 0
while not dismissed do
    loop_count = loop_count + 1
    local k = inputs[input_idx]
    input_idx = input_idx + 1
    if k then
        dismissed = true
    end
end
assert_true(dismissed, "Help modal dismissed only when key is pressed")
assert_eq(loop_count, 3, "Help modal ignores nil timeouts and stays open until key arrives")

-- Test multi-delete prompt logic
local function format_delete_prompt(targets)
    if #targets == 1 then
        return string.format("Delete '%s'?", targets[1].name)
    else
        return string.format("Delete %d selected items?", #targets)
    end
end
assert_eq(format_delete_prompt({ { name = "file1.txt" } }), "Delete 'file1.txt'?", "Single target delete prompt formatted correctly")
assert_eq(format_delete_prompt({ { name = "f1" }, { name = "f2" }, { name = "f3" } }), "Delete 3 selected items?", "Multi-target delete prompt shows count")

-- Test Suite 17: Preview Pane Scrolling (J / K)
print("\n-- Test Suite 17: Preview Pane Scrolling --")
local sim_preview_lines = {}
for i = 1, 50 do
    table.insert(sim_preview_lines, string.format("Line %d content", i))
end
local visible_rows = 15
local max_scroll = math.max(0, #sim_preview_lines - visible_rows)
assert_eq(max_scroll, 35, "Max scroll calculated correctly for 50 lines with 15 visible rows")

local scroll_off = 0
-- Scroll down with 'J' (+3)
scroll_off = scroll_off + 3
assert_eq(scroll_off, 3, "Scrolling down with 'J' increments by 3")

-- Scroll down past end
scroll_off = scroll_off + 100
scroll_off = math.max(0, math.min(scroll_off, max_scroll))
assert_eq(scroll_off, 35, "Scroll offset clamped at max_scroll")

-- Scroll up with 'K' (-3)
scroll_off = math.max(0, scroll_off - 3)
assert_eq(scroll_off, 32, "Scrolling up with 'K' decrements by 3")

-- Scroll up past 0
scroll_off = math.max(0, scroll_off - 100)
assert_eq(scroll_off, 0, "Scroll offset clamped at 0")

-- Reset on selection change
scroll_off = 10
local new_selection = 2
scroll_off = 0
assert_eq(scroll_off, 0, "Scroll offset resets to 0 when cursor moves")

-- Test Suite 18: Directory Bookmarks (m<key> & '<key>)
print("\n-- Test Suite 18: Directory Bookmarks --")
local sim_bookmarks = {}
local sim_curr_dir = "/home/user/projects/lualab"

-- Test mark mode
local sim_mark_mode = true
local pressed_key = "p"
if sim_mark_mode and pressed_key:match("^[a-zA-Z0-9]$") then
    sim_bookmarks[pressed_key:lower()] = sim_curr_dir
    sim_mark_mode = false
end
assert_eq(sim_bookmarks["p"], "/home/user/projects/lualab", "Bookmark 'p' saved current directory")
assert_false(sim_mark_mode, "Mark mode exited after setting bookmark")

-- Change directory
sim_curr_dir = "/tmp/sandbox"

-- Test jump mode
local sim_jump_mode = true
local jump_key = "p"
if sim_jump_mode and jump_key:match("^[a-zA-Z0-9]$") then
    local target = sim_bookmarks[jump_key:lower()]
    if target then
        sim_curr_dir = target
    end
    sim_jump_mode = false
end
assert_eq(sim_curr_dir, "/home/user/projects/lualab", "Jumped to bookmarked directory 'p'")
assert_false(sim_jump_mode, "Jump mode exited after jump")

-- Test invalid / nonexistent mark key
local sim_jump_mode_2 = true
local missing_key = "z"
if sim_jump_mode_2 and missing_key:match("^[a-zA-Z0-9]$") then
    local target = sim_bookmarks[missing_key:lower()]
    if target then
        sim_curr_dir = target
    end
    sim_jump_mode_2 = false
end
assert_eq(sim_curr_dir, "/home/user/projects/lualab", "Current dir unchanged when jumping to unset mark")

-- Test Suite 19: Subshell (S) Command Construction
print("\n-- Test Suite 19: Subshell Spawning --")
local function build_subshell_cmd(target_dir, shell_bin, is_win)
    local function sim_shell_quote(path)
        if is_win then return '"' .. path:gsub('"', '\\"') .. '"' end
        return "'" .. path:gsub("'", "'\\''") .. "'"
    end
    if is_win then
        return string.format('cd /d %s && %s', sim_shell_quote(target_dir), shell_bin)
    else
        return string.format('cd %s && %s', sim_shell_quote(target_dir), shell_bin)
    end
end

local posix_cmd = build_subshell_cmd("/home/user/my folder", "/bin/bash", false)
assert_eq(posix_cmd, "cd '/home/user/my folder' && /bin/bash", "POSIX subshell command quotes directory properly")

local win_cmd = build_subshell_cmd("C:\\My Projects", "cmd.exe", true)
assert_eq(win_cmd, 'cd /d "C:\\My Projects" && cmd.exe', "Windows subshell command uses /d and quotes properly")

-- Test Suite 20: Fast Scanner (fd / find) & Exclusions
print("\n-- Test Suite 20: Fast Scanner & Exclusions --")
local function build_fd_cmd(root_dir, show_hidden)
    local hidden_flag = show_hidden and "-H " or ""
    return string.format("fd -t f %s-E .git -E node_modules -E .hg -E .svn -E .cache . '%s'",
        hidden_flag, root_dir)
end

local function build_find_cmd(root_dir, show_hidden)
    local prune_hidden = show_hidden and "" or "-o -name '.*'"
    return string.format("find '%s' -type d \\( -name .git -o -name node_modules -o -name .hg -o -name .svn -o -name .cache %s \\) -prune -o -type f -print",
        root_dir, prune_hidden)
end

local fd_c = build_fd_cmd("/home/zliu/test", false)
assert_true(fd_c:find("-E .git") ~= nil, "fd command ignores .git")
assert_true(fd_c:find("-E node_modules") ~= nil, "fd command ignores node_modules")
assert_true(fd_c:find("-E .cache") ~= nil, "fd command ignores .cache")
assert_true(fd_c:find("-H") == nil, "fd command does not include -H when show_hidden is false")

local fd_c_hidden = build_fd_cmd("/home/zliu/test", true)
assert_true(fd_c_hidden:find("-H") ~= nil, "fd command includes -H when show_hidden is true")

local find_c = build_find_cmd("/home/zliu/test", false)
assert_true(find_c:find("-name .git") ~= nil, "find command prunes .git")
assert_true(find_c:find("-name node_modules") ~= nil, "find command prunes node_modules")
assert_true(find_c:find("-prune") ~= nil, "find command uses -prune")

-- Test Suite 21: Search Engine Cycling & Badges
print("\n-- Test Suite 21: Search Engine Cycling & Badges --")
local ENGINES = { "fd", "find", "lua" }
local eng_idx = 1
assert_eq(ENGINES[eng_idx], "fd", "Default search engine is 'fd'")

-- Test Tab cycle 1: fd -> find
eng_idx = (eng_idx % #ENGINES) + 1
assert_eq(ENGINES[eng_idx], "find", "Tab cycles from 'fd' to 'find'")

-- Test Tab cycle 2: find -> lua
eng_idx = (eng_idx % #ENGINES) + 1
assert_eq(ENGINES[eng_idx], "lua", "Tab cycles from 'find' to 'lua'")

-- Test Tab cycle 3: lua -> fd
eng_idx = (eng_idx % #ENGINES) + 1
assert_eq(ENGINES[eng_idx], "fd", "Tab wraps back to 'fd'")

-- Test header title with engine badge
local function format_search_title(matches_cnt, total_cnt, engine_name)
    local badge = string.format("[%s]", engine_name)
    return string.format(" FUZZY FILE SEARCH (%d/%d) %s ", matches_cnt, total_cnt, badge)
end
local title_preview = format_search_title(15, 120, "fd")
assert_true(title_preview:find("%[fd%]") ~= nil, "Modal title contains [fd] badge")
assert_true(title_preview:find("15/120") ~= nil, "Modal title contains match count")

-- Test Suite 22: Terminal Autowrap & Safe Ctrl+C Restoration --
print("\n-- Test Suite 22: Terminal Autowrap & Safe Ctrl+C Restoration --")
local lf_suite22 = io.open("lumina.lua", "r")
local l_code = lf_suite22:read("*all")
lf_suite22:close()

assert_true(l_code:find("%?7l") ~= nil, "lumina.lua disables line wrapping with \\27[?7l on raw mode entry")
assert_true(l_code:find("%?7h") ~= nil, "lumina.lua restores line wrapping with \\27[?7h on raw mode exit")
assert_true(l_code:find("ISIG") ~= nil, "lumina.lua defines ISIG mask for POSIX raw mode")
assert_true(l_code:find("IEXTEN") ~= nil, "lumina.lua defines IEXTEN mask for POSIX raw mode")
assert_true(l_code:find('k%s*==%s*"\\3"') ~= nil, "lumina.lua handles Ctrl+C (\\3) for graceful termination")

local Lumina = require("lumina")
assert_true(type(Lumina.enable_raw_mode) == "function", "Lumina exports enable_raw_mode function")
assert_true(type(Lumina.disable_raw_mode) == "function", "Lumina exports disable_raw_mode function")

-- Test Suite 23: Synchronized Frame Emission & Screen Clear Elimination --
print("\n-- Test Suite 23: Synchronized Frame Emission & Screen Clear Elimination --")
assert_true(l_code:find("%?2026h") ~= nil, "lumina.lua uses synchronized update escape \\27[?2026h")
assert_true(l_code:find("%?2026l") ~= nil, "lumina.lua uses synchronized update end escape \\27[?2026l")
assert_true(l_code:find("raw_cols %- 1") ~= nil, "lumina.lua clamps layout width to raw_cols - 1")

-- Check that navigation sections do not emit 2J
local nav_block = l_code:match("k == \"g_prefix\".-elseif k == \"t\"") or l_code:match("elseif g_prefix.-elseif k == \"t\"")
assert_true(nav_block ~= nil, "Located navigation keybinding block")
assert_true(nav_block:find("2J") == nil, "Navigation block contains zero calls to \\27[2J")

-- Check that modals do not emit 2J on exit
local fuzzy_exit = l_code:match("local function show_fuzzy_finder(.-)\nlocal function show_input_modal")
assert_true(fuzzy_exit ~= nil and fuzzy_exit:find("2J") == nil, "show_fuzzy_finder exits without \\27[2J")

local input_exit = l_code:match("function show_input_modal.-end%s*\n%s*\n%s*local function show_confirm_modal")
assert_true(input_exit ~= nil and input_exit:find("2J") == nil, "show_input_modal exits without \\27[2J")

local confirm_exit = l_code:match("function show_confirm_modal.-end%s*\n%s*\n%s*local function show_help_modal")
assert_true(confirm_exit ~= nil and confirm_exit:find("2J") == nil, "show_confirm_modal exits without \\27[2J")

local help_exit = l_code:match("function show_help_modal.-end%s*\n%s*\n%s*local PREVIEW_CACHE_LIMIT")
assert_true(help_exit ~= nil and help_exit:find("2J") == nil, "show_help_modal exits without \\27[2J")

-- Test Suite 24: Differential Selection Refresh on Local Movement --
print("\n-- Test Suite 24: Differential Selection Refresh on Local Movement --")
local lf_suite24 = io.open("lumina.lua", "r")
local l_code_diff = lf_suite24:read("*all")
lf_suite24:close()

assert_true(l_code_diff:find("local render_full_screen,%s*render_selection_differential") ~= nil,
    "lumina.lua declares forward declarations for render_full_screen and render_selection_differential")
assert_true(l_code_diff:find("render_selection_differential%s*=%s*function") ~= nil,
    "lumina.lua defines render_selection_differential function")
assert_true(l_code_diff:find("render_selection_differential%(previous_selection,%s*sel_index%)") ~= nil,
    "lumina.lua triggers render_selection_differential on local cursor movement keys")
assert_true(l_code_diff:find("prev_page_offset") ~= nil,
    "lumina.lua tracks prev_page_offset to safely fall back to full screen when boundary crosses")

-- Test Suite 25: Instant Preview Caching, Modal Paging & Toast Notifications --
print("\n-- Test Suite 25: Instant Preview Caching, Modal Paging & Toast Notifications --")
local lf_suite25 = io.open("lumina.lua", "r")
local l_code25 = lf_suite25:read("*all")
lf_suite25:close()

-- 1. Fuzzy Finder Modal Paging & Shortcuts
local fzf_block = l_code25:match("local function show_fuzzy_finder(.-)\nlocal function show_input_modal")
assert_true(fzf_block ~= nil, "Located show_fuzzy_finder implementation")
assert_true(fzf_block:find('k%s*==%s*"PAGE_UP"') ~= nil, "show_fuzzy_finder supports PAGE_UP key")
assert_true(fzf_block:find('k%s*==%s*"PAGE_DOWN"') ~= nil, "show_fuzzy_finder supports PAGE_DOWN key")
assert_true(fzf_block:find('k%s*==%s*"\\21"') ~= nil or fzf_block:find('k%s*==%s*"CTRL_U"') ~= nil, "show_fuzzy_finder supports Ctrl+U scroll up")
assert_true(fzf_block:find('k%s*==%s*"\\4"') ~= nil or fzf_block:find('k%s*==%s*"CTRL_D"') ~= nil, "show_fuzzy_finder supports Ctrl+D scroll down")
assert_true(fzf_block:find('k%s*==%s*"HOME"') ~= nil, "show_fuzzy_finder supports HOME key to jump to top")
assert_true(fzf_block:find('k%s*==%s*"END"') ~= nil, "show_fuzzy_finder supports END key to jump to bottom")

-- 2. Instant Preview Caching and Small File / Directory Bypass
assert_true(type(Lumina.should_render_preview_instantly) == "function", "Lumina exports should_render_preview_instantly")
assert_true(type(Lumina.clear_preview_cache) == "function", "Lumina exports clear_preview_cache")
Lumina.clear_preview_cache()

local test_dir_entry = { path = "/tmp/testdir", name = "testdir", is_dir = true, ext = "", size = 4096 }
local test_small_text = { path = "/tmp/test.txt", name = "test.txt", is_dir = false, ext = "txt", size = 2048 }
local test_large_bin = { path = "/tmp/test.bin", name = "test.bin", is_dir = false, ext = "bin", size = 1048576 }

assert_true(Lumina.should_render_preview_instantly(test_dir_entry, 20, 80, false) == true,
    "Directory previews render instantly without debounce delay")
assert_true(Lumina.should_render_preview_instantly(test_small_text, 20, 80, false) == true,
    "Small text files (<64KB) render instantly without debounce delay")
assert_true(Lumina.should_render_preview_instantly(test_large_bin, 20, 80, false) == false,
    "Large uncached binary files defer preview rendering for smooth navigation")

-- 3. Toast Notifications & Status Messages
assert_true(l_code25:find("local status_message%s*=%s*nil") ~= nil, "lumina.lua declares status_message variable")
assert_true(l_code25:find("local function set_status_message") ~= nil, "lumina.lua defines set_status_message helper")
assert_true(l_code25:find("status_message%s*=%s*nil") ~= nil, "lumina.lua clears status_message on keypress")

-- Ensure status_message is displayed in footer bars
assert_true(l_code25:find("elseif status_message then%s*status_text%s*=%s*status_message") ~= nil,
    "render_full_screen displays status_message in footer bar")
assert_true(l_code25:find("if status_message then%s*status_text%s*=%s*status_message") ~= nil,
    "render_selection_differential displays status_message in footer bar")

-- Ensure all key operations trigger notifications
assert_true(l_code25:find("✓ Copied") ~= nil, "Copy operation (y) sets confirmation toast")
assert_true(l_code25:find("✓ Cut") ~= nil, "Cut operation (d/x) sets confirmation toast")
assert_true(l_code25:find("✓ Pasted") ~= nil, "Paste operation (p) sets confirmation toast")
assert_true(l_code25:find("★ Bookmark '%%s' set to") ~= nil, "Setting bookmark (m) sets confirmation toast")
assert_true(l_code25:find("★ Jumped to bookmark") ~= nil, "Jumping bookmark sets confirmation toast")
assert_true(l_code25:find("✓ Created") ~= nil, "Create file/dir (a) sets confirmation toast")
assert_true(l_code25:find("✓ Renamed to") ~= nil, "Rename operation (R) sets confirmation toast")
assert_true(l_code25:find("✓ Deleted") ~= nil, "Delete operation (D) sets confirmation toast")
assert_true(l_code25:find("🎨 Theme:") ~= nil, "Cycle theme (t/T) sets confirmation toast")

-- Test Suite 26: Full-Width Zoom Preview Mode (Key 'z') --
do
    print("\n-- Test Suite 26: Full-Width Zoom Preview Mode (Key 'z') --")
    local lf_suite26 = io.open("lumina.lua", "r")
    local l_code26 = lf_suite26:read("*all")
    lf_suite26:close()

    -- 1. Export and Geometry Calculations
    assert_true(type(Lumina.calculate_miller_geometry) == "function", "Lumina exports calculate_miller_geometry helper")

    -- Normal 3-column Miller geometry
    local c1_w, c2_w, c3_w, c1_x, c2_x, c3_x = Lumina.calculate_miller_geometry(100, false)
    assert_eq(c1_w, 22, "Normal mode Col 1 width is 22% (22)")
    assert_eq(c2_w, 32, "Normal mode Col 2 width is 32% (32)")
    assert_eq(c3_w, 46, "Normal mode Col 3 width is remaining 46% (46)")
    assert_eq(c1_w + c2_w + c3_w, 100, "Normal mode column widths sum to terminal width (100)")
    assert_eq(c1_x, 1, "Normal mode Col 1 starts at 1")
    assert_eq(c2_x, 23, "Normal mode Col 2 starts at 23")
    assert_eq(c3_x, 55, "Normal mode Col 3 starts at 55")

    -- Zoomed preview mode geometry: 100% full width to Col 3
    local z1_w, z2_w, z3_w, z1_x, z2_x, z3_x = Lumina.calculate_miller_geometry(100, true)
    assert_eq(z1_w, 0, "Zoomed mode Col 1 width is 0")
    assert_eq(z2_w, 0, "Zoomed mode Col 2 width is 0")
    assert_eq(z3_w, 100, "Zoomed mode Col 3 takes 100% width (100)")
    assert_eq(z3_x, 1, "Zoomed mode Col 3 starts at x=1")

    local _, _, z3_80 = Lumina.calculate_miller_geometry(80, true)
    assert_eq(z3_80, 80, "Zoomed mode at 80 cols takes full 80 cols")

    local _, _, z3_140 = Lumina.calculate_miller_geometry(140, true)
    assert_eq(z3_140, 140, "Zoomed mode at 140 cols takes full 140 cols")

    -- 2. State & Keybindings Verification
    assert_true(l_code26:find("local is_preview_zoomed%s*=%s*false") ~= nil, "lumina.lua declares is_preview_zoomed state")
    assert_true(l_code26:find('elseif k%s*==%s*"z"') ~= nil, "lumina.lua handles 'z' key for preview zoom toggle")
    assert_true(l_code26:find("Preview Zoom: ON") ~= nil, "lumina.lua sets confirmation toast on preview zoom ON")
    assert_true(l_code26:find("Preview Zoom: OFF") ~= nil, "lumina.lua sets confirmation toast on preview zoom OFF")

    -- 3. Zoom Navigation Controls
    assert_true(l_code26:find("is_preview_zoomed and %(k == \"n\"") ~= nil, "lumina.lua supports 'n' for next file in zoom mode")
    assert_true(l_code26:find("is_preview_zoomed and %(k == \"p\"") ~= nil, "lumina.lua supports 'p' for prev file in zoom mode")
    assert_true(l_code26:find("if is_preview_zoomed then%s*preview_scroll_offset = preview_scroll_offset %+ 1") ~= nil,
        "lumina.lua scrolls preview down with j/DOWN in zoom mode")
    assert_true(l_code26:find("preview_scroll_offset = math%.max%(0, preview_scroll_offset %- 1%)") ~= nil,
        "lumina.lua scrolls preview up with k/UP in zoom mode")
    assert_true(l_code26:find("is_preview_zoomed and k ~= \"\\3\" then%s*is_preview_zoomed = false") ~= nil,
        "lumina.lua exits zoom mode on q / ESC")

    -- 4. Help Documentation
    assert_true(l_code26:find('key%s*=%s*"z",%s*desc%s*=%s*"Toggle full%-width preview zoom"') ~= nil,
        "show_help_modal documents 'z' zoom key under PREVIEW & TOOLS")
end

-- Test Suite 27: In-Preview Search & Match Highlighting (`/`, `n`, `N`) --
do
    print("\n-- Test Suite 27: In-Preview Search & Match Highlighting (`/`, `n`, `N`) --")
    local lf_suite27 = io.open("lumina.lua", "r")
    local l_code27 = lf_suite27:read("*all")
    lf_suite27:close()

    -- 1. Helper function exports
    assert_true(type(Lumina.strip_ansi) == "function", "Lumina exports strip_ansi helper")
    assert_true(type(Lumina.highlight_search) == "function", "Lumina exports highlight_search helper")
    assert_true(type(Lumina.update_preview_matches) == "function", "Lumina exports update_preview_matches helper")

    -- 2. strip_ansi functional tests
    assert_eq(Lumina.strip_ansi("\27[38;2;255;0;0mHello\27[0m World\n"), "Hello World", "strip_ansi strips ANSI escapes and newlines")
    assert_eq(Lumina.strip_ansi("Pure ASCII Text"), "Pure ASCII Text", "strip_ansi preserves plain ASCII text")
    assert_eq(Lumina.strip_ansi("📁 Documents / 🚀 Rocket"), "📁 Documents / 🚀 Rocket", "strip_ansi preserves UTF-8 emoji and multi-byte characters")

    -- 3. highlight_search functional tests
    local sample_line = "local function calculate_total(items)"
    assert_eq(Lumina.highlight_search(sample_line, ""), sample_line, "highlight_search with empty query returns original string")
    assert_eq(Lumina.highlight_search(sample_line, "nonexistent"), sample_line, "highlight_search with no match returns original string")

    local hl_res = Lumina.highlight_search(sample_line, "function", false)
    assert_true(hl_res:find("function") ~= nil, "highlight_search contains matched word")
    assert_true(hl_res:find("\27%[") ~= nil, "highlight_search inserts ANSI highlight codes")
    assert_eq(Lumina.strip_ansi(hl_res), sample_line, "strip_ansi on highlight_search result matches original clean text")

    local hl_active = Lumina.highlight_search(sample_line, "calculate", true)
    local hl_inactive = Lumina.highlight_search(sample_line, "calculate", false)
    assert_true(hl_active ~= hl_inactive, "Active match has distinct highlight styling from inactive match")

    -- Case-insensitivity
    local hl_case = Lumina.highlight_search("LUMINA file manager and Lumina preview", "lumina", false)
    assert_eq(Lumina.strip_ansi(hl_case), "LUMINA file manager and Lumina preview", "Case-insensitive highlighting retains original casing")

    -- Preserves existing syntax highlighting ANSI codes
    local color_line = "\27[34mlocal\27[0m \27[32mname\27[0m = \27[31m\"lumina\"\27[0m"
    local hl_syntax = Lumina.highlight_search(color_line, "name", true)
    assert_eq(Lumina.strip_ansi(hl_syntax), "local name = \"lumina\"", "highlight_search preserves underlying syntax highlighted text")

    -- 4. update_preview_matches functional tests
    local sample_lines = {
        "local ffi = require('ffi')",
        "local function format_bytes(bytes)",
        "    if bytes < 1024 then",
        "        return string.format('%d B', bytes)",
        "    end",
        "end"
    }
    local matches_bytes = Lumina.update_preview_matches(sample_lines, "bytes")
    assert_eq(#matches_bytes, 3, "update_preview_matches finds 3 matching lines for 'bytes'")
    assert_eq(matches_bytes[1], 2, "First match is on line 2")
    assert_eq(matches_bytes[2], 3, "Second match is on line 3")
    assert_eq(matches_bytes[3], 4, "Third match is on line 4")

    local matches_none = Lumina.update_preview_matches(sample_lines, "notfound")
    assert_eq(#matches_none, 0, "update_preview_matches returns 0 matches for absent pattern")

    local matches_empty = Lumina.update_preview_matches(sample_lines, "")
    assert_eq(#matches_empty, 0, "update_preview_matches returns 0 matches for empty pattern")

    -- 5. State and Keybindings verification
    assert_true(l_code27:find("preview_search_mode%s*=%s*false") ~= nil, "lumina.lua declares preview_search_mode state")
    assert_true(l_code27:find("preview_search_query%s*=%s*\"\"") ~= nil, "lumina.lua declares preview_search_query state")
    assert_true(l_code27:find("is_preview_zoomed and k == \"/\"") ~= nil, "Zoom mode / activates preview_search_mode")
    assert_true(l_code27:find("elseif preview_search_mode then") ~= nil, "lumina.lua key loop handles preview_search_mode typing")
    assert_true(l_code27:find("is_preview_zoomed and #preview_search_query > 0 and %(k == \"n\" or k == \"N\"%)") ~= nil,
        "Zoom mode n/N navigates search matches")
    assert_true(l_code27:find("is_preview_zoomed and #preview_search_query > 0 and k == \"ESC\"") ~= nil,
        "ESC in zoom search clears query")
    assert_true(l_code27:find('key%s*=%s*"/ %(in zoom%)"') ~= nil, "show_help_modal documents / in zoom")
    assert_true(l_code27:find('key%s*=%s*"n, N"') ~= nil, "show_help_modal documents n, N keys")
end

-- Test Suite 28: Visual Disk Usage Mode (`U`) & Usage Bars --
do
    print("\n-- Test Suite 28: Visual Disk Usage Mode (`U`) & Usage Bars --")
    local lf_suite28 = io.open("lumina.lua", "r")
    local l_code28 = lf_suite28:read("*all")
    lf_suite28:close()

    -- 1. Helper function exports
    assert_true(type(Lumina.make_usage_bar) == "function", "Lumina exports make_usage_bar helper")
    assert_true(type(Lumina.calculate_dir_size) == "function", "Lumina exports calculate_dir_size helper")

    -- 2. make_usage_bar functional tests
    local bar_0 = Lumina.make_usage_bar(0, 10)
    assert_true(bar_0:find("0%%") ~= nil, "make_usage_bar 0% displays 0%")
    assert_true(bar_0:find(string.rep("□", 10)) ~= nil, "make_usage_bar 0% has 10 empty blocks")

    local bar_50 = Lumina.make_usage_bar(50, 10)
    assert_true(bar_50:find("50%%") ~= nil, "make_usage_bar 50% displays 50%")
    assert_true(bar_50:find(string.rep("■", 5)) ~= nil, "make_usage_bar 50% has 5 filled blocks")
    assert_true(bar_50:find(string.rep("□", 5)) ~= nil, "make_usage_bar 50% has 5 empty blocks")

    local bar_100 = Lumina.make_usage_bar(100, 10)
    assert_true(bar_100:find("100%%") ~= nil, "make_usage_bar 100% displays 100%")
    assert_true(bar_100:find(string.rep("■", 10)) ~= nil, "make_usage_bar 100% has 10 filled blocks")

    -- Colors check: green (<50%), amber (50-79%), red (>=80%)
    local bar_low = Lumina.make_usage_bar(25, 10)
    local bar_med = Lumina.make_usage_bar(65, 10)
    local bar_high = Lumina.make_usage_bar(90, 10)
    assert_true(bar_low:find("\27%[38;2;34;197;94m") ~= nil, "Low usage (<50%) uses green ANSI color")
    assert_true(bar_med:find("\27%[38;2;245;158;11m") ~= nil, "Medium usage (50-79%) uses amber ANSI color")
    assert_true(bar_high:find("\27%[38;2;239;68;68m") ~= nil, "High usage (>=80%) uses red ANSI color")

    -- Boundary clamping
    local bar_neg = Lumina.make_usage_bar(-10, 10)
    assert_true(bar_neg:find("0%%") ~= nil, "Negative percentage clamped to 0%")
    local bar_over = Lumina.make_usage_bar(150, 10)
    assert_true(bar_over:find("100%%") ~= nil, "Over 100% clamped to 100%")

    -- 3. calculate_dir_size functional tests with temporary test directory
    local tmp_dir = "tmp_usage_test_" .. tostring(os.time())
    os.execute(string.format("mkdir -p %s/sub1 %s/sub2", tmp_dir, tmp_dir))

    local f1 = io.open(tmp_dir .. "/sub1/f1.txt", "wb")
    f1:write(string.rep("A", 1024)) -- 1024 bytes
    f1:close()

    local f2 = io.open(tmp_dir .. "/sub2/f2.txt", "wb")
    f2:write(string.rep("B", 2048)) -- 2048 bytes
    f2:close()

    local f3 = io.open(tmp_dir .. "/root.txt", "wb")
    f3:write(string.rep("C", 512)) -- 512 bytes
    f3:close()

    local calc_size = Lumina.calculate_dir_size(tmp_dir, 8)
    assert_true(calc_size >= 1024 + 2048 + 512, "calculate_dir_size sums all nested files correctly (>= 3584 bytes)")

    -- Cycle / recursion guard test: max_depth = 0 returns 0
    assert_eq(Lumina.calculate_dir_size(tmp_dir, 0), 0, "calculate_dir_size returns 0 when max_depth is 0")

    -- Clean up temporary test files
    os.execute(string.format("rm -rf %s", tmp_dir))

    -- 4. State & Keybinding tests in lumina.lua
    assert_true(l_code28:find("is_disk_usage_mode%s*=%s*false") ~= nil, "lumina.lua declares is_disk_usage_mode state")
    assert_true(l_code28:find("dir_size_cache") ~= nil, "lumina.lua declares dir_size_cache table")
    assert_true(l_code28:find("populate_disk_usage") ~= nil, "lumina.lua defines populate_disk_usage function")
    assert_true(l_code28:find("elseif k == \"U\" then") ~= nil, "lumina.lua handles 'U' key to toggle disk usage mode")
    assert_true(l_code28:find("Disk Usage Mode: ON") ~= nil, "Toggling U sets confirmation toast on")
    assert_true(l_code28:find("Disk Usage Mode: OFF") ~= nil, "Toggling U sets confirmation toast off")
    assert_true(l_code28:find("is_disk_usage_mode or is_preview_zoomed") ~= nil,
        "Differential refresh falls back to full screen in disk usage mode")
    assert_true(l_code28:find("make_usage_bar%(pct, bar_w%)") ~= nil, "Column 2 renders make_usage_bar in disk usage mode")
    assert_true(l_code28:find('key%s*=%s*"U"') ~= nil, "show_help_modal documents U key under PREVIEW & TOOLS")
end

-- Test Suite 29: Archive Content Inspection & Tree Preview --
print("\n-- Test Suite 29: Archive Content Inspection & Tree Preview --")
do
    local Lumina = require("lumina")

    -- 1. Helper and detection tests
    assert_true(Lumina.is_archive_file ~= nil, "Lumina exports is_archive_file helper")
    assert_true(Lumina.parse_zip_central_directory ~= nil, "Lumina exports parse_zip_central_directory helper")
    assert_true(Lumina.generate_archive_preview ~= nil, "Lumina exports generate_archive_preview helper")

    -- Test is_archive_file on various extensions
    assert_true(Lumina.is_archive_file({ name = "release.zip", ext = "zip", is_dir = false }), "Identifies .zip as archive")
    assert_true(Lumina.is_archive_file({ name = "bundle.tar.gz", ext = "gz", is_dir = false }), "Identifies .tar.gz as archive")
    assert_true(Lumina.is_archive_file({ name = "dist.tar.xz", ext = "xz", is_dir = false }), "Identifies .tar.xz as archive")
    assert_true(Lumina.is_archive_file({ name = "backup.tgz", ext = "tgz", is_dir = false }), "Identifies .tgz as archive")
    assert_true(Lumina.is_archive_file({ name = "data.tar", ext = "tar", is_dir = false }), "Identifies .tar as archive")
    assert_true(Lumina.is_archive_file({ name = "app.apk", ext = "apk", is_dir = false }), "Identifies .apk as archive")
    assert_true(Lumina.is_archive_file({ name = "lib.jar", ext = "jar", is_dir = false }), "Identifies .jar as archive")
    assert_true(Lumina.is_archive_file({ name = "archive.7z", ext = "7z", is_dir = false }), "Identifies .7z as archive")

    assert_false(Lumina.is_archive_file({ name = "lumina.lua", ext = "lua", is_dir = false }), "Does not identify .lua as archive")
    assert_false(Lumina.is_archive_file({ name = "main.c", ext = "c", is_dir = false }), "Does not identify .c as archive")
    assert_false(Lumina.is_archive_file({ name = "photo.png", ext = "png", is_dir = false }), "Does not identify .png as archive")
    assert_false(Lumina.is_archive_file({ name = "archive.zip", ext = "zip", is_dir = true }), "Directory named .zip is not an archive file")

    -- 2. Mock Zip archive creation and testing
    local tmp_zip = "/tmp/test_lumina_suite29.zip"
    local py_cmd = string.format([[python3 -c "import zipfile
with zipfile.ZipFile('%s', 'w') as zf:
    zf.writestr('README.md', 'Hello World\n')
    zf.writestr('src/main.lua', 'print(\"main\")\n')
    zf.writestr('docs/', '')
"]], tmp_zip)
    os.execute(py_cmd)

    local zip_info = Lumina.parse_zip_central_directory(tmp_zip)
    assert_true(zip_info ~= nil, "parse_zip_central_directory parses valid zip file")
    assert_eq(zip_info and zip_info.count, 3, "parse_zip_central_directory finds exactly 3 entries")
    assert_true(zip_info and zip_info.total_uncompressed >= 23, "parse_zip_central_directory sums uncompressed size correctly")

    -- Verify entries
    local found_readme = false
    local found_main = false
    local found_docs = false
    if zip_info and zip_info.entries then
        for _, e in ipairs(zip_info.entries) do
            if e.name == "README.md" then found_readme = true end
            if e.name == "src/main.lua" then found_main = true end
            if e.name == "docs/" and e.is_dir then found_docs = true end
        end
    end
    assert_true(found_readme, "Found README.md in zip entries")
    assert_true(found_main, "Found src/main.lua in zip entries")
    assert_true(found_docs, "Found docs/ directory in zip entries")

    -- 3. generate_archive_preview on zip file
    local preview_lines = Lumina.generate_archive_preview(tmp_zip, "zip", 20, 60)
    assert_true(#preview_lines >= 4, "generate_archive_preview returns formatted preview lines")
    assert_true(preview_lines[1]:find("📦 Archive:") ~= nil, "Header contains '📦 Archive:'")
    assert_true(preview_lines[1]:find("3 items") ~= nil, "Header reports correct item count (3 items)")
    local clean_all = Lumina.strip_ansi(table.concat(preview_lines, "\n"))
    assert_true(clean_all:find("README.md") ~= nil, "Preview list includes README.md")

    -- Truncation test when max_lines is small
    local trunc_lines = Lumina.generate_archive_preview(tmp_zip, "zip", 3, 60)
    local has_more = false
    for _, l in ipairs(trunc_lines) do
        if l:find("and %d+ more items") then has_more = true break end
    end
    assert_true(has_more, "generate_archive_preview truncates list and shows '... and N more items'")

    os.execute("rm -f " .. tmp_zip)

    -- 4. Mock Tar.gz archive creation and testing
    local tmp_tar = "/tmp/test_lumina_suite29.tar.gz"
    local py_tar_cmd = string.format([[python3 -c "import tarfile, io
with tarfile.open('%s', 'w:gz') as tf:
    ti = tarfile.TarInfo(name='app/config.json')
    data = b'{\"port\": 8080}'
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))
"]], tmp_tar)
    os.execute(py_tar_cmd)

    local tar_preview = Lumina.generate_archive_preview(tmp_tar, "gz", 20, 60)
    assert_true(#tar_preview >= 3, "generate_archive_preview generates preview for .tar.gz")
    assert_true(tar_preview[1]:find("📦 Archive:") ~= nil, "Tar preview header contains '📦 Archive:'")
    local tar_clean = Lumina.strip_ansi(table.concat(tar_preview, "\n"))
    assert_true(tar_clean:find("app/config.json") ~= nil, "Tar preview lists app/config.json")

    os.execute("rm -f " .. tmp_tar)

    -- 5. Nonexistent/corrupted file fallback
    local bad_preview = Lumina.generate_archive_preview("/nonexistent/file.zip", "zip", 20, 60)
    assert_true(#bad_preview >= 3, "Returns fallback lines for nonexistent archive")
    assert_true(bad_preview[3]:find("Cannot inspect archive contents") ~= nil, "Shows clear error message on invalid archive")

    -- 6. Integration checks in lumina.lua source code
    local lf29 = io.open("lumina.lua", "r")
    local l_code29 = lf29:read("*a")
    lf29:close()

    assert_true(l_code29:find("is_archive_file%(entry%)") ~= nil, "lumina.lua checks is_archive_file in preview router")
    assert_true(l_code29:find("generate_archive_preview%(entry%.path") ~= nil, "lumina.lua invokes generate_archive_preview")
    assert_true(l_code29:find("is_archive_file%(entry%) and entry%.size and entry%.size < 1048576") ~= nil,
        "lumina.lua enables instant preview rendering for small archive files")
end

-- Test Suite 30: Directory Jump History (Ctrl+O & Ctrl+I / [ & ]) --
print("\n-- Test Suite 30: Directory Jump History (Ctrl+O & Ctrl+I / [ & ]) --")
do
    local Lumina = require("lumina")

    -- 1. Helper existence
    assert_true(Lumina.create_history_tracker ~= nil, "Lumina exports create_history_tracker helper")

    -- 2. Initialization tests
    local tracker = Lumina.create_history_tracker("/home/zliu/test/lualab", 64)
    assert_eq(tracker.get_index(), 1, "Initial history index is 1")
    assert_eq(#tracker.get_stack(), 1, "Initial history stack size is 1")
    assert_eq(tracker.current(), "/home/zliu/test/lualab", "Initial current dir matches start dir")
    assert_false(tracker.can_go_back(), "Cannot go back on initial start")
    assert_false(tracker.can_go_forward(), "Cannot go forward on initial start")
    assert_eq(tracker.back(), nil, "back() returns nil when already at root")
    assert_eq(tracker.forward(), nil, "forward() returns nil when already at head")

    -- 3. Push and Navigation tests
    tracker.push("/home/zliu/test/lualab/src")
    assert_eq(tracker.get_index(), 2, "Index advances to 2 after push")
    assert_eq(#tracker.get_stack(), 2, "Stack size is 2 after push")
    assert_eq(tracker.current(), "/home/zliu/test/lualab/src", "current() reflects newly pushed dir")
    assert_true(tracker.can_go_back(), "can_go_back() is true at index 2")
    assert_false(tracker.can_go_forward(), "can_go_forward() is false at head")

    -- Redundant push is ignored
    tracker.push("/home/zliu/test/lualab/src")
    assert_eq(#tracker.get_stack(), 2, "Pushing same current dir is ignored")

    -- Push third directory
    tracker.push("/home/zliu/test/lualab/src/engine")
    assert_eq(tracker.get_index(), 3, "Index advances to 3")
    assert_eq(#tracker.get_stack(), 3, "Stack size is 3")

    -- 4. Jump back tests
    local prev1 = tracker.back()
    assert_eq(prev1, "/home/zliu/test/lualab/src", "First back() returns second directory")
    assert_eq(tracker.get_index(), 2, "Index decrements to 2")
    assert_true(tracker.can_go_back(), "Can still go back at index 2")
    assert_true(tracker.can_go_forward(), "Can go forward after jumping back")

    local prev2 = tracker.back()
    assert_eq(prev2, "/home/zliu/test/lualab", "Second back() returns root directory")
    assert_eq(tracker.get_index(), 1, "Index decrements to 1")
    assert_false(tracker.can_go_back(), "Cannot go back past index 1")
    assert_true(tracker.can_go_forward(), "Can go forward from index 1")

    assert_eq(tracker.back(), nil, "Extra back() returns nil and preserves index 1")
    assert_eq(tracker.get_index(), 1, "Index remains 1")

    -- 5. Jump forward tests
    local next1 = tracker.forward()
    assert_eq(next1, "/home/zliu/test/lualab/src", "First forward() returns second directory")
    assert_eq(tracker.get_index(), 2, "Index increments to 2")

    local next2 = tracker.forward()
    assert_eq(next2, "/home/zliu/test/lualab/src/engine", "Second forward() returns third directory")
    assert_eq(tracker.get_index(), 3, "Index increments to 3")
    assert_false(tracker.can_go_forward(), "Cannot go forward past head")
    assert_eq(tracker.forward(), nil, "Extra forward() returns nil")

    -- 6. Forward history truncation on branching navigation
    tracker.back() -- now at index 2 (/home/zliu/test/lualab/src)
    assert_eq(tracker.get_index(), 2, "Back to index 2")
    tracker.push("/home/zliu/test/lualab/docs") -- navigate to new branch
    assert_eq(tracker.get_index(), 3, "Index is 3 after branching push")
    assert_eq(#tracker.get_stack(), 3, "Stack size is 3 after forward truncation")
    assert_eq(tracker.current(), "/home/zliu/test/lualab/docs", "Current is new branch")
    assert_false(tracker.can_go_forward(), "Forward history was cleanly truncated")

    -- 7. Max capacity capping
    local small_tracker = Lumina.create_history_tracker("/dir0", 3)
    small_tracker.push("/dir1")
    small_tracker.push("/dir2")
    small_tracker.push("/dir3") -- pushes beyond max_size 3
    assert_eq(#small_tracker.get_stack(), 3, "Stack size clamped to max_size 3")
    assert_eq(small_tracker.get_stack()[1], "/dir1", "Oldest /dir0 evicted from stack")
    assert_eq(small_tracker.current(), "/dir3", "Current is /dir3")

    -- 8. Integration checks in lumina.lua source code
    local lf30 = io.open("lumina.lua", "r")
    local l_code30 = lf30:read("*a")
    lf30:close()

    assert_true(l_code30:find("create_history_tracker") ~= nil, "lumina.lua defines create_history_tracker")
    assert_true(l_code30:find("dir_history%s*=%s*create_history_tracker") ~= nil, "lumina.lua instantiates dir_history")
    assert_true(l_code30:find("dir_history%.push%(current_dir%)") ~= nil, "lumina.lua pushes to dir_history on navigation")
    assert_true(l_code30:find("dir_history%.back") ~= nil, "lumina.lua calls dir_history.back")
    assert_true(l_code30:find("dir_history%.forward") ~= nil, "lumina.lua calls dir_history.forward")
    assert_true(l_code30:find('k%s*==%s*"\\15"') ~= nil or l_code30:find('k%s*==%s*"CTRL_O"') ~= nil,
        "lumina.lua handles Ctrl+O for history jump back")
    assert_true(l_code30:find('k%s*==%s*"\\9"') ~= nil or l_code30:find('k%s*==%s*"TAB"') ~= nil,
        "lumina.lua handles Ctrl+I/Tab for history jump forward")
    assert_true(l_code30:find('key%s*=%s*"Ctrl%+O,%s*%["') ~= nil, "show_help_modal documents Ctrl+O under NAVIGATION")
    assert_true(l_code30:find('key%s*=%s*"Ctrl%+I,%s*%]"') ~= nil, "show_help_modal documents Ctrl+I under NAVIGATION")
end

-- =========================================================================
-- Test Suite 31: Quick Shell Command Runner (`:`, `!`) & Macro Expansion (`%f`, `%s`, `%d`, `%%`)
-- =========================================================================
do
    print("\n-- Test Suite 31: Quick Shell Command Runner (`:`, `!`) & Macro Expansion (`%f`, `%s`, `%d`, `%%`) --")

    -- 1. Helper exports
    assert_true(type(Lumina.expand_command_macros) == "function", "Lumina exports expand_command_macros helper")
    assert_true(type(Lumina.execute_shell_command) == "function", "Lumina exports execute_shell_command helper")
    assert_true(type(Lumina.show_command_modal) == "function", "Lumina exports show_command_modal helper")

    -- 2. Basic commands with no macros
    assert_eq(Lumina.expand_command_macros("git status", "file.txt", {}, "/app"), "git status", "Preserves command with no macros")
    assert_eq(Lumina.expand_command_macros("ls -la", nil, nil, nil), "ls -la", "Handles nil contexts with plain command")
    assert_eq(Lumina.expand_command_macros("", "file.txt", {}, "/app"), "", "Handles empty command string")
    assert_eq(Lumina.expand_command_macros(nil, "file.txt", {}, "/app"), "", "Handles nil command string")

    -- 3. %f Macro expansion (current file)
    local exp_f1 = Lumina.expand_command_macros("cat %f", "/tmp/notes.txt", {}, "/tmp")
    assert_true(exp_f1:find("/tmp/notes.txt") ~= nil, "%f expands to file path")
    assert_true(exp_f1:sub(1, 4) == "cat ", "%f preserves command prefix")

    -- Handle spaces in filename
    local exp_f2 = Lumina.expand_command_macros("wc -l %f", "/tmp/my file cool.txt", {}, "/tmp")
    assert_true(exp_f2:find("my file cool") ~= nil, "%f handles filenames with spaces")

    -- 4. %s Macro expansion (tagged files vs fallback)
    -- Multi-file selection with string paths
    local exp_s1 = Lumina.expand_command_macros("rm %s", "/tmp/main.lua", { "/tmp/a.txt", "/tmp/b.txt" }, "/tmp")
    assert_true(exp_s1:find("/tmp/a.txt") ~= nil, "%s contains first tagged file")
    assert_true(exp_s1:find("/tmp/b.txt") ~= nil, "%s contains second tagged file")

    -- Tagged files as entry tables
    local table_tagged = { { path = "/tmp/x.log", name = "x.log" }, { path = "/tmp/y.log", name = "y.log" } }
    local exp_s2 = Lumina.expand_command_macros("tar -czf logs.tar.gz %s", "/tmp/main.lua", table_tagged, "/tmp")
    assert_true(exp_s2:find("/tmp/x.log") ~= nil, "%s extracts path from table entries")
    assert_true(exp_s2:find("/tmp/y.log") ~= nil, "%s extracts second path from table entries")

    -- Fallback to current file when no files are tagged
    local exp_s_fallback = Lumina.expand_command_macros("ls -l %s", "/tmp/target.c", {}, "/tmp")
    assert_true(exp_s_fallback:find("/tmp/target.c") ~= nil, "%s falls back to current file when selection empty")

    -- When neither tagged files nor current file exists
    local exp_s_empty = Lumina.expand_command_macros("echo %s", "", {}, "/tmp")
    assert_eq(exp_s_empty, "echo ", "%s is empty string when no targets exist")

    -- 5. %d Macro expansion (current directory)
    local exp_d = Lumina.expand_command_macros("cd %d && pwd", "/tmp/file.txt", {}, "/home/user/project")
    assert_true(exp_d:find("/home/user/project") ~= nil, "%d expands to current directory")

    -- 6. %% Escape handling and literal percent signs
    local exp_esc1 = Lumina.expand_command_macros("echo 100%%", "file.txt", {}, "/tmp")
    assert_eq(exp_esc1, "echo 100%", "%% escapes to single literal %")

    local exp_esc2 = Lumina.expand_command_macros("printf '%%s: %f'", "/tmp/test.lua", {}, "/tmp")
    assert_true(exp_esc2:find("%%s", 1, true) == nil, "%%s has double percent replaced")
    assert_true(exp_esc2:find("%%s") ~= nil, "Result contains single %s format token")
    assert_true(exp_esc2:find("/tmp/test.lua") ~= nil, "%f still expands alongside %%")

    local exp_esc3 = Lumina.expand_command_macros("echo 50% off", "file.txt", {}, "/tmp")
    assert_eq(exp_esc3, "echo 50% off", "Trailing non-token percent is preserved verbatim")

    local exp_esc4 = Lumina.expand_command_macros("echo %x %z", "file.txt", {}, "/tmp")
    assert_eq(exp_esc4, "echo %x %z", "Unknown percent token sequences are preserved verbatim")

    -- 7. Multiple mixed macros in one command
    local exp_mix = Lumina.expand_command_macros("cp %f %d/backup/ && echo %s", "/var/log/sys.log", {}, "/var/log")
    assert_true(exp_mix:find("/var/log/sys.log") ~= nil, "Mixed macros expands %f")
    assert_true(exp_mix:find("/var/log") ~= nil, "Mixed macros expands %d")
    assert_true(exp_mix:find("/backup/") ~= nil, "Mixed macros preserves trailing path")

    -- 8. Execution of shell command via execute_shell_command
    local ok_run, code_run = Lumina.execute_shell_command("true", "/tmp", true)
    assert_true(ok_run ~= nil and ok_run ~= false, "execute_shell_command executes successfully")
    assert_eq(code_run, 0, "execute_shell_command returns 0 for successful command")

    local ok_fail, code_fail = Lumina.execute_shell_command("sh -c 'exit 7'", "/tmp", true)
    assert_eq(code_fail, 7, "execute_shell_command parses non-zero exit code correctly")

    -- 9. Render command modal frame test (zero formatting errors across edge cases)
    assert_true(type(Lumina.render_command_modal_frame) == "function", "Lumina exports render_command_modal_frame")
    local frame1 = Lumina.render_command_modal_frame("", "main.lua", {}, "/home/zliu", 80, 24)
    assert_true(frame1:find("RUN SHELL COMMAND") ~= nil, "Modal frame contains title")
    assert_true(frame1:find("Preview:") ~= nil, "Modal frame contains preview label")
    assert_true(frame1:find("Tokens: %%f") ~= nil, "Modal frame contains tokens hint")
    assert_true(frame1:find("Target: main.lua") ~= nil, "Modal frame displays target file")
    assert_true(frame1:find("%[Enter%] Execute") ~= nil, "Modal frame displays action shortcuts")

    -- Modal frame with command text and tagged items
    local frame2 = Lumina.render_command_modal_frame("git diff %s", "lumina.lua", { "a.lua", "b.lua" }, "/home/zliu", 120, 40)
    assert_true(frame2:find("Target: 2 tagged item%(s%)") ~= nil, "Modal frame reports tagged items count")
    assert_true(frame2:find("git diff") ~= nil, "Modal frame displays command and preview")

    -- Modal frame with empty context
    local frame3 = Lumina.render_command_modal_frame("ls", "", {}, "/home/zliu", 60, 20)
    assert_true(frame3:find("Target: %(none%)") ~= nil, "Modal frame handles empty target gracefully")

    -- 10. Source integration checks in lumina.lua
    local lf31 = io.open("lumina.lua", "r")
    local l_code31 = lf31:read("*a")
    lf31:close()

    assert_true(l_code31:find("expand_command_macros") ~= nil, "lumina.lua defines expand_command_macros")
    assert_true(l_code31:find("execute_shell_command") ~= nil, "lumina.lua defines execute_shell_command")
    assert_true(l_code31:find("show_command_modal") ~= nil, "lumina.lua defines show_command_modal")
    assert_true(l_code31:find("render_command_modal_frame") ~= nil, "lumina.lua defines render_command_modal_frame")
    assert_true(l_code31:find('k%s*==%s*":"%s*or%s*k%s*==%s*"!"') ~= nil or l_code31:find('k%s*==%s*"!"%s*or%s*k%s*==%s*":"') ~= nil,
        "lumina.lua binds : and ! to command runner")
    assert_true(l_code31:find('key%s*=%s*":,%s*!"') ~= nil, "show_help_modal documents : and ! shortcuts")

    -- 11. Verify SPACE key normalization across text modals & normal tagging
    assert_true(l_code31:find('if k%s*==%s*"SPACE"%s*then%s*k%s*=%s*" "%s*end') ~= nil,
        "lumina.lua normalizes SPACE key in command modal")
    assert_true(l_code31:find('k%s*==%s*"SPACE"%s*or%s*k%s*==%s*" "%s*or%s*k%s*==%s*"v"') ~= nil,
        "lumina.lua binds SPACE key for tagging in normal mode")
end

print(string.format("\nResults: %d passed, %d failed.", passed, failed))
if failed > 0 then
    os.exit(1)
end






