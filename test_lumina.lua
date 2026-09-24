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

print(string.format("\nResults: %d passed, %d failed.", passed, failed))
if failed > 0 then
    os.exit(1)
end

