#!/usr/bin/env luajit
--[[
    test_mdview_gui.lua — headless + Windows smoke tests for mdview --gui

    Covers the pure layout, hit-testing, scrolling and key-mapping helpers,
    the GUI state and symbol-tree loading, offscreen GDI rendering to a BMP,
    and a real Win32 window driven with posted input messages. Tests that
    need the Win32 GUI are skipped on other platforms.
]]

local script_dir = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. package.path
local mdview = require("mdview")
local ffi = require("ffi")
local IS_WINDOWS = (ffi.os == "Windows")
local NULL_DEVICE = IS_WINDOWS and "NUL" or "/dev/null"

local luajit_bin = "luajit"
if arg and arg[-1] and #arg[-1] > 0 then
    luajit_bin = arg[-1]
end

local passed = 0
local failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
    end
end

local function eq(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then
        error(label or "expected truthy value", 2)
    end
end

local function metrics()
    return {
        dpi = 96,
        cell_w = 8,
        cell_h = 21,
        tree_row_h = 22,
        header_h = 28,
        status_h = 26,
        padding = 10,
        tree_indent = 14,
        tree_marker = 16,
        text_offset = 2,
        tree_ratio = 0.28,
        tree_min = 200,
        tree_max = 340,
        tree_break = 560,
        min_doc_width = 240,
    }
end

local function ensure_directory(path)
    if IS_WINDOWS then
        return os.execute('mkdir "' .. path .. '" 2>' .. NULL_DEVICE)
    end
    return os.execute("mkdir -p '" .. path .. "'")
end

local function write_file(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

local function read_u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset, offset + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

test("layout splits tree and document panes", function()
    local layout = mdview.gui_layout(1120, 800, metrics())
    eq(layout.width, 1120, "width")
    eq(layout.height, 800, "height")
    eq(layout.content_height, 774, "content height")
    eq(layout.tree_width, 313, "tree width")
    eq(layout.separator, 1, "separator")
    eq(layout.doc_x, 314, "document x")
    eq(layout.doc_width, 806, "document width")
    eq(layout.rows, 35, "document rows")
    eq(layout.tree_rows, 33, "tree rows")
end)

test("layout clamps the tree on narrow windows", function()
    local layout = mdview.gui_layout(640, 480, metrics())
    eq(layout.tree_width, 200, "minimum tree width")
    eq(layout.doc_x, 201, "document x")
    eq(layout.doc_width, 439, "document width")
    eq(layout.rows, 20, "rows at 640x480")
    eq(layout.tree_rows, 19, "tree rows at 640x480")

    local narrow = mdview.gui_layout(500, 400, metrics())
    eq(narrow.tree_width, 0, "tree hidden below break")
    eq(narrow.separator, 0, "no separator")
    eq(narrow.doc_x, 0, "document fills width")
    eq(narrow.doc_width, 500, "document width fills")
    eq(narrow.tree_rows, 0, "no tree rows")
end)

test("layout stays valid at tiny sizes", function()
    for _, size in ipairs({ { 1, 1 }, { 24, 10 }, { 100, 20 }, { 559, 359 } }) do
        local layout = mdview.gui_layout(size[1], size[2], metrics())
        truthy(layout.doc_width >= 1, "document width at " .. size[1])
        truthy(layout.rows >= 1, "rows at " .. size[1])
        truthy(layout.content_height >= 1, "content height at " .. size[1])
        truthy(layout.header_height <= layout.content_height, "header fits")
    end
    local tall = metrics()
    tall.cell_h = 2000
    local layout = mdview.gui_layout(800, 400, tall)
    eq(layout.rows, 1, "at least one document row")
end)

test("document columns respect padding and minimum", function()
    local layout = mdview.gui_layout(1120, 800, metrics())
    eq(mdview.gui_document_columns(layout, metrics()), 98, "wide columns")
    local narrow = mdview.gui_layout(640, 480, metrics())
    eq(mdview.gui_document_columns(narrow, metrics()), 52, "narrow columns")
    local tiny = { doc_width = 100, width = 100, doc_x = 0 }
    eq(mdview.gui_document_columns(tiny, metrics()), 20, "never below 20 columns")
end)

test("hit testing maps rows and panes", function()
    local layout = mdview.gui_layout(1120, 800, metrics())
    local m = metrics()
    eq(mdview.gui_hit_test(layout, m, 10, 28).pane, "tree", "first tree row pane")
    eq(mdview.gui_hit_test(layout, m, 10, 28).row, 1, "first tree row")
    eq(mdview.gui_hit_test(layout, m, 10, 49).row, 1, "row boundary above")
    eq(mdview.gui_hit_test(layout, m, 10, 50).row, 2, "row boundary below")
    eq(mdview.gui_hit_test(layout, m, 10, 27).pane, "header", "header row")
    eq(mdview.gui_hit_test(layout, m, 10, 774).pane, "status", "status bar")
    eq(mdview.gui_hit_test(layout, m, 400, 28).pane, "document", "document pane")
    eq(mdview.gui_hit_test(layout, m, 400, 28).row, 1, "first document row")
    eq(mdview.gui_hit_test(layout, m, 313, 100).pane, "separator", "separator")
    eq(mdview.gui_hit_test(layout, m, -1, 10).pane, "none", "out of bounds")
    eq(mdview.gui_hit_test(layout, m, 10, 799).pane, "status", "last pixel row")
end)

test("scrolling clamps at both ends", function()
    eq(mdview.gui_scroll_top(1, 100, 10, "down"), 2, "down")
    eq(mdview.gui_scroll_top(50, 100, 10, "up"), 49, "up")
    eq(mdview.gui_scroll_top(50, 100, 10, "page_down"), 59, "page down")
    eq(mdview.gui_scroll_top(50, 100, 10, "page_up"), 41, "page up")
    eq(mdview.gui_scroll_top(50, 100, 10, "top"), 1, "top")
    eq(mdview.gui_scroll_top(1, 100, 10, "bottom"), 91, "bottom")
    eq(mdview.gui_scroll_top(1, 9, 30, "up"), 1, "short document cannot scroll")
    eq(mdview.gui_scroll_top(99, 9, 30, "bottom"), 1, "short bottom is top")
    eq(mdview.gui_scroll_top(1, 100, 10, "unknown"), 1, "unknown action is a no-op")
end)

test("ensure_visible keeps the selected row in view", function()
    eq(mdview.gui_ensure_visible(1, 20, 10, 100), 11, "scrolls down")
    eq(mdview.gui_ensure_visible(11, 1, 10, 100), 1, "scrolls up")
    eq(mdview.gui_ensure_visible(3, 8, 10, 100), 3, "already visible")
    eq(mdview.gui_ensure_visible(1, 100, 10, 100), 91, "clamps at the end")
    eq(mdview.gui_ensure_visible(1, 1, 30, 5), 1, "short list")
end)

test("key mapping differs per pane", function()
    eq(mdview.gui_key_action("TAB", "tree"), "switch", "tab from tree")
    eq(mdview.gui_key_action("TAB", "document"), "switch", "tab from document")
    eq(mdview.gui_key_action("LEFT", "tree"), "collapse", "left folds")
    eq(mdview.gui_key_action("RIGHT", "tree"), "expand", "right unfolds")
    eq(mdview.gui_key_action("ENTER", "tree"), "open", "enter opens")
    eq(mdview.gui_key_action("ESC", "tree"), "escape", "escape leaves tree")
    eq(mdview.gui_key_action("ESC", "document"), nil, "escape in document")
    eq(mdview.gui_key_action("PAGE_DOWN", "document"), "page_down", "page down")
    eq(mdview.gui_key_action("SPACE", "document"), "page_down", "space pages")
    eq(mdview.gui_key_action("HOME", "document"), "top", "home")
    eq(mdview.gui_key_action("END", "document"), "bottom", "end")
    eq(mdview.gui_key_action("LEFT", "document"), nil, "left inert in document")
    eq(mdview.gui_key_action("z", "tree"), nil, "unknown key")
end)

test("CLI rejects incompatible --gui invocations", function()
    local first = os.tmpname()
    local snapshot_status = os.execute(string.format(
        "%s mdview.lua --gui --snapshot 80x24 README.md > %s 2> %s",
        luajit_bin, NULL_DEVICE, first))
    truthy(snapshot_status ~= 0, "--gui with --snapshot fails")
    local file = assert(io.open(first, "rb"))
    local message = file:read("*a")
    file:close()
    os.remove(first)
    truthy(message:find("--gui cannot be combined with --snapshot", 1, true),
        "conflict message: " .. message)

    local second = os.tmpname()
    local stdin_status = os.execute(string.format(
        "%s -e \"io.write('# stdin\\\\n')\" | %s mdview.lua --gui - > %s 2>&1",
        luajit_bin, luajit_bin, second))
    truthy(stdin_status ~= 0, "--gui with stdin fails")
    local stdin_file = assert(io.open(second, "rb"))
    local stdin_message = stdin_file:read("*a")
    stdin_file:close()
    os.remove(second)
    truthy(stdin_message:find("cannot read from stdin", 1, true),
        "stdin message: " .. stdin_message)
end)

if not IS_WINDOWS then
    test("GUI state reports a clear platform error", function()
        local state, err = mdview.gui_create_state({ file = "." })
        eq(state, nil, "no state")
        truthy(tostring(err):find("--gui requires Windows", 1, true), "platform message")
        local code, run_err = mdview.gui_run(nil, nil)
        eq(code, 1, "run refuses")
        truthy(tostring(run_err):find("--gui requires Windows", 1, true), "run message")
    end)
else
    local fixture = "_mdview_gui_test"
    local long_path = fixture .. "/long.md"

    local function prepare_fixture()
        ensure_directory(fixture)
        ensure_directory(fixture .. "/guides")
        write_file(fixture .. "/README.md",
            "# Fixture\n\nA **bold** word and `code`.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n")
        write_file(fixture .. "/guides/install.md", "# Install\n\nStep one.\n")
        write_file(fixture .. "/guides/usage.md", "# Usage\n\nStep two.\n")
        write_file(fixture .. "/.hidden.md", "# Hidden\n")
        write_file(fixture .. "/notes.txt", "not markdown\n")
        local long = { "# Long\n\n" }
        for index = 1, 120 do
            long[#long + 1] = string.format("Line %d of the long document.\n\n", index)
        end
        write_file(long_path, table.concat(long))
    end

    local function remove_fixture()
        if IS_WINDOWS then
            os.execute(string.format('rmdir /s /q "%s" >%s 2>%s',
                fixture:gsub("/", "\\"), NULL_DEVICE, NULL_DEVICE))
        else
            os.execute(string.format('rm -rf "%s"', fixture))
        end
    end

    local function entry_index(state, name)
        for index, node in ipairs(state.browser.entries) do
            if node.name == name then
                return index
            end
        end
        return nil
    end

    prepare_fixture()

    test("GUI state loads the Markdown tree lazily", function()
        assert(mdview.set_theme("dark"))
        local state, err = mdview.gui_create_state({
            file = fixture, images = false, numbers = true,
        })
        truthy(state, "state created: " .. tostring(err))
        local names = {}
        for _, node in ipairs(state.browser.entries) do
            names[#names + 1] = node.name
        end
        eq(#names, 4, "root plus three visible entries")
        eq(names[2], "guides", "folders sorted first")
        truthy(entry_index(state, "README.md"), "README in tree")
        truthy(entry_index(state, "long.md"), "long document in tree")
        truthy(not table.concat(names, ","):find("hidden", 1, true), "hidden skipped")
        truthy(not table.concat(names, ","):find("notes.txt", 1, true), "text skipped")
        truthy(state.view and #state.view.lines > 0, "placeholder document")
        eq(state.focus, "tree", "directory opens on the tree")
        mdview.gui_destroy(state)
    end)

    test("expanding a folder from the keyboard reveals its files", function()
        ffi.cdef[[ int __stdcall PostMessageW(void *, uint32_t, uintptr_t, intptr_t); ]]
        local user32 = ffi.load("user32")
        local state = assert(mdview.gui_create_state({
            file = fixture, images = false, numbers = true,
        }))
        local folder = entry_index(state, "guides")
        truthy(folder, "guides in tree")
        local code = mdview.gui_run(state, {
            auto_close_ms = 400,
            on_ready = function(_, hwnd)
                for _ = 2, folder do
                    user32.PostMessageW(hwnd, 0x0100, 0x28, 0)
                end
                user32.PostMessageW(hwnd, 0x0100, 0x27, 0)
            end,
        })
        eq(code, 0, "run exit code")
        truthy(entry_index(state, "install.md"), "expanded folder lists install.md")
        truthy(#state.browser.entries > 4, "tree grew after expanding")
        mdview.gui_destroy(state)
    end)

    test("a file path opens its folder as the tree root", function()
        local opened = assert(mdview.gui_create_state({
            file = fixture .. "/guides/install.md", images = false, numbers = true,
        }))
        eq(opened.title, "install.md", "document title")
        truthy(opened.view and #opened.view.lines >= 3, "document rendered")
        eq(opened.browser.root.name, "guides", "tree rooted at the file's folder")
        truthy(entry_index(opened, "install.md"), "file selected in tree")
        truthy(entry_index(opened, "usage.md"), "sibling file listed in tree")
        mdview.gui_destroy(opened)
    end)

    test("open_path renders a Markdown file", function()
        local state = assert(mdview.gui_create_state({
            file = fixture, images = false, numbers = true,
        }))
        truthy(mdview.gui_open_path(state, fixture .. "/README.md"), "file opened")
        eq(state.title, "README.md", "title updated")
        local text = {}
        for _, line in ipairs(state.view.lines) do
            text[#text + 1] = line.text
        end
        local joined = table.concat(text, "\n")
        truthy(joined:find("Fixture", 1, true), "heading rendered")
        truthy(joined:find("│ A", 1, true) and joined:find("┌", 1, true), "table rendered")
        eq(mdview.gui_open_path(state, fixture .. "/missing.md"), false, "missing file")
        truthy(state.message:find("Cannot open", 1, true), "visible error message")
        mdview.gui_destroy(state)
    end)

    test("offscreen snapshot writes a valid bitmap", function()
        local state = assert(mdview.gui_create_state({
            file = long_path, images = false, numbers = true,
        }))
        local shot = "_mdview_gui_test.bmp"
        local ok, err = mdview.gui_snapshot(state, 720, 480, shot)
        truthy(ok, "snapshot written: " .. tostring(err))
        local file = assert(io.open(shot, "rb"))
        local header = file:read(26)
        local size = file:seek("end")
        file:close()
        eq(header:sub(1, 2), "BM", "bitmap magic")
        eq(read_u32(header, 19), 720, "bitmap width")
        eq(read_u32(header, 23), 480, "bitmap height")
        truthy(size > 54, "bitmap has pixels")
        os.remove(shot)
        mdview.gui_destroy(state)
    end)

    test("window runs, paints, scrolls and closes", function()
        ffi.cdef[[ int __stdcall PostMessageW(void *, uint32_t, uintptr_t, intptr_t); ]]
        local user32 = ffi.load("user32")
        local state = assert(mdview.gui_create_state({
            file = long_path, images = false, numbers = true,
        }))
        local code, err = mdview.gui_run(state, {
            auto_close_ms = 400,
            on_ready = function(_, hwnd)
                user32.PostMessageW(hwnd, 0x0100, 0x23, 0)
            end,
        })
        eq(code, 0, "run exit code " .. tostring(err))
        truthy(state.paints and state.paints >= 1, "at least one painted frame")
        local maximum = math.max(1, #state.view.lines - state.layout.rows + 1)
        truthy(maximum > 10, "document scrolls")
        eq(state.view.top, maximum, "End reached the bottom")
        eq(state.hwnd, nil, "window handle released")
        mdview.gui_destroy(state)
    end)

    test("window opens files through the tree", function()
        ffi.cdef[[ int __stdcall PostMessageW(void *, uint32_t, uintptr_t, intptr_t); ]]
        local user32 = ffi.load("user32")
        local key_down, key_return = 0x28, 0x0D
        local state = assert(mdview.gui_create_state({
            file = fixture, images = false, numbers = true,
        }))
        local readme = entry_index(state, "README.md")
        truthy(readme, "README in tree")
        local code = mdview.gui_run(state, {
            auto_close_ms = 400,
            on_ready = function(_, hwnd)
                for _ = 2, readme do
                    user32.PostMessageW(hwnd, 0x0100, key_down, 0)
                end
                user32.PostMessageW(hwnd, 0x0100, key_return, 0)
            end,
        })
        eq(code, 0, "run exit code")
        truthy(state.path:find("README.md", 1, true), "README opened from tree")
        truthy(state.view and #state.view.lines > 3, "opened document rendered")
        mdview.gui_destroy(state)
    end)

    test("theme switch keeps the GUI renderable", function()
        assert(mdview.set_theme("light"))
        local state = assert(mdview.gui_create_state({
            file = fixture .. "/README.md", images = false, numbers = true,
        }))
        local shot = "_mdview_gui_light.bmp"
        local ok, err = mdview.gui_snapshot(state, 640, 480, shot)
        truthy(ok, "light snapshot: " .. tostring(err))
        truthy(io.open(shot, "rb"), "light bitmap exists")
        os.remove(shot)
        mdview.gui_destroy(state)
        assert(mdview.set_theme("dark"))
    end)

    remove_fixture()
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
os.exit(0)
