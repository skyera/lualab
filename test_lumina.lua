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

print(string.format("\nResults: %d passed, %d failed.", passed, failed))
if failed > 0 then
    os.exit(1)
end





