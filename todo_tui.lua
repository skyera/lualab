#!/usr/bin/env luajit
--[[
    todo_tui.lua (todo_lite.lua)
    A fast, beautiful, and keyboard-driven Todo TUI written in pure LuaJIT with FFI.

    Features:
    - POSIX ioctl(TIOCGWINSZ) via FFI for dynamic terminal window resizing.
    - POSIX termios raw mode + poll() for instant single-keypress non-blocking responsiveness.
    - Alternate screen buffer (\27[?1049h) & cursor management with safe recovery.
    - 24-bit Truecolor modern theme (Nord / Catppuccin inspired).
    - Multi-pane layout:
      [Sidebar] Views & Filter Categories with live task counts.
      [List] Task table with checkboxes, priority badges, tags, titles, due dates.
      [Inspector] Task details card showing full notes, timestamps, and status.
    - Interactive in-TUI modal dialogs (Add, Edit, Delete Confirm, Search, Help)
      operating completely within raw mode with zero screen flicker.
    - Live Search / Fuzzy substring filter.
    - Task reordering (J / K), priority cycling (p), and tag cycling (t).
    - JSON persistence with automatic migration/fallback to tasks.txt.
    - CLI options: --list, --add "Task", --done <id>, --help.

    Keybindings:
    - ↑ / ↓ or k / j   : Navigate task list
    - Space / Enter    : Toggle task completion ([ ] <-> [✔])
    - a                : Add new task (opens modal popup)
    - e                : Edit highlighted task title & notes
    - d / x            : Delete highlighted task (with confirmation)
    - p                : Quick cycle priority (High -> Med -> Low)
    - t                : Quick cycle category / tag
    - J / K            : Move task down / up (reorder)
    - Tab / 1..8       : Switch sidebar views (All, Active, Done, High Prio, Tags)
    - /                : Search & filter tasks
    - c                : Clean / archive completed tasks
    - ? or h           : Toggle help cheat sheet
    - q / ESC          : Quit
]]

local ffi = require("ffi")

-- Safely require JSON library (built-in in repo)
local json_ok, json = pcall(require, "json")
if not json_ok then
    -- Minimal fallback JSON serializer if json.lua is missing
    json = {
        encode = function(tbl)
            local function ser(val)
                local t = type(val)
                if t == "string" then
                    return string.format("%q", val):gsub("\n", "\\n")
                elseif t == "number" or t == "boolean" then
                    return tostring(val)
                elseif t == "table" then
                    local is_arr = (#val > 0)
                    local parts = {}
                    if is_arr then
                        for _, v in ipairs(val) do table.insert(parts, ser(v)) end
                        return "[" .. table.concat(parts, ",") .. "]"
                    else
                        for k, v in pairs(val) do
                            table.insert(parts, string.format("%q:%s", tostring(k), ser(v)))
                        end
                        return "{" .. table.concat(parts, ",") .. "}"
                    end
                end
                return "null"
            end
            return ser(tbl)
        end,
        decode = function(str)
            return {}
        end
    }
end

-- =========================================================================
-- 1. FFI POSIX Terminal, Polling, and Window Size C Definitions
-- =========================================================================
ffi.cdef[[
    struct winsize {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
    };
    int ioctl(int fd, unsigned long request, void *argp);
    int isatty(int fd);

    typedef unsigned char cc_t;
    typedef unsigned int  speed_t;
    typedef unsigned int  tcflag_t;

    struct termios {
        tcflag_t c_iflag;
        tcflag_t c_oflag;
        tcflag_t c_cflag;
        tcflag_t c_lflag;
        cc_t     c_line;
        cc_t     c_cc[32];
        speed_t  c_ispeed;
        speed_t  c_ospeed;
    };

    int tcgetattr(int fd, struct termios *termios_p);
    int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);

    struct pollfd {
        int   fd;
        short events;
        short revents;
    };
    int poll(struct pollfd *fds, unsigned long nfds, int timeout);
    long read(int fd, void *buf, size_t count);
]]

local TIOCGWINSZ   = 0x5413
local STDIN_FILENO = 0
local TCSANOW      = 0
local ICANON       = 2
local ECHO         = 8
local POLLIN       = 1

local orig_termios = ffi.new("struct termios")
local raw_termios  = ffi.new("struct termios")
local in_raw_mode  = false

local function enable_raw_mode()
    if ffi.C.isatty(STDIN_FILENO) ~= 1 then return false end
    ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
    ffi.C.tcgetattr(STDIN_FILENO, raw_termios)
    raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
    ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
    in_raw_mode = true

    -- Switch to alternate screen buffer, hide cursor, clear screen
    io.write("\27[?1049h\27[?25l\27[2J\27[H")
    io.flush()
    return true
end

local function disable_raw_mode()
    if in_raw_mode then
        -- Return to main screen buffer, show cursor, reset styling
        io.write("\27[?1049l\27[?25h\27[0m")
        io.flush()
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
        in_raw_mode = false
    end
end

local function get_terminal_size()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    return 100, 30
end

local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
local key_buf = ffi.new("char[64]")

local function read_key(timeout_ms)
    timeout_ms = timeout_ms or 50
    local ret = ffi.C.poll(pfd, 1, timeout_ms)
    if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
        local n = ffi.C.read(STDIN_FILENO, key_buf, 64)
        if n > 0 then
            local c0 = key_buf[0]
            if c0 == 27 then
                if n >= 3 and key_buf[1] == 91 then
                    local c2 = key_buf[2]
                    if c2 == 65 then return "UP" end
                    if c2 == 66 then return "DOWN" end
                    if c2 == 67 then return "RIGHT" end
                    if c2 == 68 then return "LEFT" end
                    if c2 == 72 then return "HOME" end
                    if c2 == 70 then return "END" end
                    if c2 == 53 and n >= 4 and key_buf[3] == 126 then return "PAGE_UP" end
                    if c2 == 54 and n >= 4 and key_buf[3] == 126 then return "PAGE_DOWN" end
                end
                return "ESC"
            elseif c0 == 9 then
                return "TAB"
            elseif c0 == 10 or c0 == 13 then
                return "ENTER"
            elseif c0 == 32 then
                return "SPACE"
            elseif c0 == 127 or c0 == 8 then
                return "BACKSPACE"
            elseif c0 == 3 then
                return "CTRL_C"
            elseif c0 >= 32 and c0 <= 126 then
                return string.char(c0)
            else
                -- UTF-8 multibyte sequence
                return ffi.string(key_buf, n)
            end
        end
    end
    return nil
end

-- =========================================================================
-- 2. Visual Formatting, Unicode & Colors (24-bit Truecolor)
-- =========================================================================
local C = {
    reset        = "\27[0m",
    bold         = "\27[1m",
    dim          = "\27[2m",
    italic       = "\27[3m",
    strike       = "\27[9m",

    -- App Header & Chrome
    hdr_bg       = "\27[48;2;15;23;42m",     -- Slate 900
    hdr_title    = "\27[1;38;2;56;189;248m", -- Cyan 400
    hdr_subtitle = "\27[38;2;148;163;184m",  -- Slate 400
    border       = "\27[38;2;71;85;105m",   -- Slate 600
    border_focus = "\27[1;38;2;56;189;248m", -- Cyan 400
    pane_title   = "\27[1;38;2;241;245;249m",

    -- Task List Item Selection
    sel_bg       = "\27[48;2;30;58;138m\27[1;38;2;241;245;249m", -- Royal Blue
    sel_cursor   = "\27[1;38;2;56;189;248m▶ ",

    -- Status Checkmarks
    done_chk     = "\27[1;38;2;34;197;94m[✔]\27[0m",  -- Emerald Green
    pending_chk  = "\27[38;2;148;163;184m[ ]\27[0m",   -- Muted Gray

    -- Priority Badges
    prio_high    = "\27[1;38;2;239;68;68m🔴 HIGH\27[0m",
    prio_med     = "\27[1;38;2;245;158;11m🟡 MED \27[0m",
    prio_low     = "\27[1;38;2;34;197;94m🟢 LOW \27[0m",

    -- Category Tags
    tag_dev      = "\27[38;2;168;85;247m[Dev]\27[0m",
    tag_work     = "\27[38;2;59;130;246m[Work]\27[0m",
    tag_personal = "\27[38;2;236;72;153m[Personal]\27[0m",
    tag_study    = "\27[38;2;20;184;166m[Study]\27[0m",
    tag_general  = "\27[38;2;148;163;184m[General]\27[0m",

    -- Status bar messages
    msg_success  = "\27[1;38;2;34;197;94m",
    msg_warn     = "\27[1;38;2;234;179;8m",
    msg_info     = "\27[1;38;2;56;189;248m",

    -- Modal Dialogs
    modal_border = "\27[1;38;2;212;175;55m", -- Amber gold
    modal_title  = "\27[1;38;2;255;225;120m",
    modal_bg     = "\27[48;2;15;23;42m",
}

local function visual_len(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    local w = 0
    for c in clean:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #c == 1 then
            w = w + 1
        else
            -- Non-ASCII / CJK / Emojis take 2 columns
            w = w + 2
        end
    end
    return w
end

local function truncate(str, max_w)
    local len = visual_len(str)
    if len <= max_w then return str end
    if max_w <= 3 then return string.rep(".", math.max(0, max_w)) end

    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    local out = {}
    local curr = 0
    for c in clean:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local cw = (#c == 1) and 1 or 2
        if curr + cw > max_w - 3 then break end
        table.insert(out, c)
        curr = curr + cw
    end
    return table.concat(out) .. "..."
end

local function pad_string(str, width, align)
    local vlen = visual_len(str)
    local pad = math.max(0, width - vlen)
    if align == "right" then
        return string.rep(" ", pad) .. str
    elseif align == "center" then
        local l = math.floor(pad / 2)
        local r = pad - l
        return string.rep(" ", l) .. str .. string.rep(" ", r)
    else
        return str .. string.rep(" ", pad)
    end
end

-- =========================================================================
-- 3. Data Model & Storage Management
-- =========================================================================
local DB_FILE = "todo_tasks.json"
local LEGACY_FILE = "tasks.txt"

local function default_tasks()
    return {
        {
            id = 1,
            title = "Explore LuaJIT FFI direct C calling conventions",
            notes = "Test pointer manipulation, struct caching, and benchmark vs standard Lua.",
            done = true,
            priority = "high",
            category = "Dev",
            due = "Today",
            created_at = "2026-09-10 14:00",
            completed_at = "2026-09-10 16:30"
        },
        {
            id = 2,
            title = "Implement Todo TUI with POSIX raw mode & ioctl",
            notes = "Build responsive keyboard-driven TUI with modals, filtering, and JSON storage.",
            done = true,
            priority = "high",
            category = "Dev",
            due = "Today",
            created_at = "2026-09-11 08:30",
            completed_at = "2026-09-11 09:15"
        },
        {
            id = 3,
            title = "Review particle physics simulator memory layout",
            notes = "Ensure 3D particle array stays within L1 CPU cache lines.",
            done = false,
            priority = "high",
            category = "Dev",
            due = "Tomorrow",
            created_at = "2026-09-11 08:45"
        },
        {
            id = 4,
            title = "Prepare slides for team engineering demo",
            notes = "Highlight performance comparisons between Lua tables and FFI cdata.",
            done = false,
            priority = "med",
            category = "Work",
            due = "Friday",
            created_at = "2026-09-11 08:50"
        },
        {
            id = 5,
            title = "Read chapter 4 of High Performance Computing",
            notes = "Focus on cache hierarchy, branch prediction, and SIMD vectorization.",
            done = false,
            priority = "low",
            category = "Study",
            due = "Sunday",
            created_at = "2026-09-11 09:00"
        },
        {
            id = 6,
            title = "Pick up fresh groceries for the weekend",
            notes = "Apples, tea leaves, whole wheat bread, and milk.",
            done = false,
            priority = "med",
            category = "Personal",
            due = "Saturday",
            created_at = "2026-09-11 09:05"
        }
    }
end

local function load_tasks()
    -- 1. Try reading JSON database
    local f = io.open(DB_FILE, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(json.decode, content)
        if ok and type(data) == "table" and #data > 0 then
            return data
        end
    end

    -- 2. Fallback: Check if legacy tasks.txt exists
    local lf = io.open(LEGACY_FILE, "r")
    if lf then
        local tasks = {}
        local id_counter = 1
        for line in lf:lines() do
            local done_str, txt = line:match("^(%d);%s*(.+)$")
            if not done_str then
                txt = line:match("^%s*(.-)%s*$")
                done_str = "0"
            end
            if txt and #txt > 0 then
                table.insert(tasks, {
                    id = id_counter,
                    title = txt,
                    notes = "",
                    done = (done_str == "1"),
                    priority = "med",
                    category = "General",
                    due = "None",
                    created_at = os.date("%Y-%m-%d %H:%M")
                })
                id_counter = id_counter + 1
            end
        end
        lf:close()
        if #tasks > 0 then return tasks end
    end

    -- 3. Return default initial starter tasks
    return default_tasks()
end

local function save_tasks(tasks)
    local f = io.open(DB_FILE, "w")
    if f then
        f:write(json.encode(tasks))
        f:close()
    end
end

-- =========================================================================
-- 4. TUI Layout & Drawing Helpers
-- =========================================================================
local function draw_box_row(x, y, w, text)
    local clr = truncate(text, w - 2)
    local vlen = visual_len(clr)
    local pad = string.rep(" ", math.max(0, w - 2 - vlen))
    return string.format("\27[%d;%dH%s%s", y, x + 1, clr, pad)
end

local function draw_pane(out, x, y, w, h, title, is_focused)
    local bcol = is_focused and C.border_focus or C.border
    local title_str = title and string.format(" %s%s%s ", C.pane_title, title, bcol) or ""
    local t_len = title and (visual_len(title) + 2) or 0
    local top_fill = string.rep("─", math.max(0, w - 2 - t_len))

    table.insert(out, string.format("\27[%d;%dH%s╭%s%s╮%s", y, x, bcol, title_str, top_fill, C.reset))
    for i = 1, h - 2 do
        table.insert(out, string.format("\27[%d;%dH%s│\27[%d;%dH│%s", y + i, x, bcol, y + i, x + w - 1, C.reset))
    end
    local bot_fill = string.rep("─", math.max(0, w - 2))
    table.insert(out, string.format("\27[%d;%dH%s╰%s╯%s", y + h - 1, x, bcol, bot_fill, C.reset))
end

local function render_tag(tag)
    if tag == "Dev" then return C.tag_dev
    elseif tag == "Work" then return C.tag_work
    elseif tag == "Personal" then return C.tag_personal
    elseif tag == "Study" then return C.tag_study
    else return C.tag_general
    end
end

local function render_priority(prio)
    if prio == "high" then return C.prio_high
    elseif prio == "med" then return C.prio_med
    else return C.prio_low
    end
end

-- =========================================================================
-- 5. Main Application State & Logic
-- =========================================================================
local VIEWS = {
    { id = "all",      label = "📋 All Tasks" },
    { id = "active",   label = "⚡ Active" },
    { id = "done",     label = "✅ Completed" },
    { id = "high",     label = "🔴 High Priority" },
    { id = "dev",      label = "🏷️ Dev" },
    { id = "work",     label = "🏷️ Work" },
    { id = "personal", label = "🏷️ Personal" },
    { id = "study",    label = "🏷️ Study" },
}

local function run_tui(is_snapshot)
    if not is_snapshot then
        if not enable_raw_mode() then
            is_snapshot = true
        end
    end

    local tasks = load_tasks()
    local cur_view_idx = 1
    local sel_idx = 1
    local scroll_offset = 0
    local search_query = ""
    local active_pane = "tasks" -- "sidebar" or "tasks"
    local status_msg = "Welcome to Todo-TUI! Press [?] for keybindings cheat sheet."
    local status_color = C.msg_info

    -- Modal states: nil | "add" | "edit" | "delete" | "search" | "help"
    local modal = nil
    local modal_input = { title = "", notes = "", priority = "high", category = "Dev", field = 1 }

    -- Helper to get filtered task list
    local function get_visible_tasks()
        local cur_view = VIEWS[cur_view_idx].id
        local list = {}
        for _, t in ipairs(tasks) do
            local match_view = false
            if cur_view == "all" then match_view = true
            elseif cur_view == "active" then match_view = (not t.done)
            elseif cur_view == "done" then match_view = t.done
            elseif cur_view == "high" then match_view = (t.priority == "high")
            elseif cur_view == "dev" then match_view = (t.category == "Dev")
            elseif cur_view == "work" then match_view = (t.category == "Work")
            elseif cur_view == "personal" then match_view = (t.category == "Personal")
            elseif cur_view == "study" then match_view = (t.category == "Study")
            end

            if match_view then
                if search_query == "" then
                    table.insert(list, t)
                else
                    local q = search_query:lower()
                    local in_title = (t.title or ""):lower():find(q, 1, true)
                    local in_notes = (t.notes or ""):lower():find(q, 1, true)
                    local in_tag   = (t.category or ""):lower():find(q, 1, true)
                    if in_title or in_notes or in_tag then
                        table.insert(list, t)
                    end
                end
            end
        end
        return list
    end

    -- Render Frame
    local function render()
        local term_w, term_h = get_terminal_size()
        local out = {}

        -- 1. Top Header Bar
        local total_cnt = #tasks
        local done_cnt = 0
        for _, t in ipairs(tasks) do if t.done then done_cnt = done_cnt + 1 end end
        local pct = (total_cnt > 0) and math.floor((done_cnt / total_cnt) * 100) or 0

        -- Mini progress bar
        local bar_len = 16
        local filled = math.floor((pct / 100) * bar_len)
        local bar_str = string.rep("█", filled) .. string.rep("░", bar_len - filled)

        local title_left = string.format(" 📋 %sTODO TUI%s  (LuaJIT FFI Engine) ", C.bold .. C.hdr_title, C.reset)
        local stats_right = string.format(" [%s] %3d%%  (%d/%d done) ", bar_str, pct, done_cnt, total_cnt)
        local head_fill = math.max(0, term_w - visual_len(title_left) - visual_len(stats_right))

        table.insert(out, string.format("\27[1;1H%s%s%s%s%s\27[0m",
            C.hdr_bg, title_left, string.rep(" ", head_fill), stats_right, C.reset))

        -- 2. Layout Geometry
        local sidebar_w = math.max(22, math.min(28, math.floor(term_w * 0.25)))
        local main_w = term_w - sidebar_w
        local usable_h = term_h - 2 -- minus header & footer

        local list_h = math.max(8, math.floor(usable_h * 0.65))
        local detail_h = usable_h - list_h
        local start_y = 2

        -- 3. Left Sidebar Pane (Views & Categories)
        draw_pane(out, 1, start_y, sidebar_w, usable_h, "1. Views & Tags", active_pane == "sidebar")

        for i, v in ipairs(VIEWS) do
            -- Count matching items for each view
            local count = 0
            for _, t in ipairs(tasks) do
                if v.id == "all" then count = count + 1
                elseif v.id == "active" and (not t.done) then count = count + 1
                elseif v.id == "done" and t.done then count = count + 1
                elseif v.id == "high" and t.priority == "high" then count = count + 1
                elseif v.id == "dev" and t.category == "Dev" then count = count + 1
                elseif v.id == "work" and t.category == "Work" then count = count + 1
                elseif v.id == "personal" and t.category == "Personal" then count = count + 1
                elseif v.id == "study" and t.category == "Study" then count = count + 1
                end
            end

            local is_sel = (i == cur_view_idx)
            local row_str
            if is_sel then
                row_str = string.format("%s▶ %s (%d)%s", C.sel_bg, v.label, count, C.reset)
            else
                row_str = string.format("  %s (%d)", v.label, count)
            end
            table.insert(out, draw_box_row(1, start_y + i, sidebar_w, row_str))
        end

        -- Keybinding shortcuts summary at bottom of sidebar
        local sc_y = start_y + #VIEWS + 2
        if sc_y < start_y + usable_h - 6 then
            table.insert(out, draw_box_row(1, sc_y, sidebar_w, C.dim .. "── Shortcuts ──" .. C.reset))
            table.insert(out, draw_box_row(1, sc_y + 1, sidebar_w, " [Space] Toggle Done"))
            table.insert(out, draw_box_row(1, sc_y + 2, sidebar_w, " [a] Add  [e] Edit"))
            table.insert(out, draw_box_row(1, sc_y + 3, sidebar_w, " [d] Del  [p] Prio"))
            table.insert(out, draw_box_row(1, sc_y + 4, sidebar_w, " [t] Tag  [/] Search"))
            table.insert(out, draw_box_row(1, sc_y + 5, sidebar_w, " [J/K] Reorder task"))
            table.insert(out, draw_box_row(1, sc_y + 6, sidebar_w, " [?] Help [q] Quit"))
        end

        -- 4. Right Top Pane: Task List Table
        local visible_tasks = get_visible_tasks()
        if sel_idx > #visible_tasks then sel_idx = math.max(1, #visible_tasks) end

        -- Viewport scrolling adjustment
        local max_visible_rows = list_h - 3
        if sel_idx < scroll_offset + 1 then
            scroll_offset = sel_idx - 1
        elseif sel_idx > scroll_offset + max_visible_rows then
            scroll_offset = sel_idx - max_visible_rows
        end

        local filter_label = VIEWS[cur_view_idx].label
        if search_query ~= "" then
            filter_label = filter_label .. string.format(" [Filter: %q]", search_query)
        end
        local list_title = string.format("2. Task List: %s (%d items)", filter_label, #visible_tasks)
        draw_pane(out, sidebar_w + 1, start_y, main_w, list_h, list_title, active_pane == "tasks")

        -- Column Header Row
        local th_str = string.format("  %s %-6s %-10s %-8s %-32s %-10s%s",
            C.dim, "Status", "Priority", "Tag", "Description", "Due", C.reset)
        table.insert(out, draw_box_row(sidebar_w + 1, start_y + 1, main_w, th_str))
        table.insert(out, draw_box_row(sidebar_w + 1, start_y + 2, main_w, C.border .. string.rep("─", main_w - 2) .. C.reset))

        -- Task Rows
        if #visible_tasks == 0 then
            table.insert(out, draw_box_row(sidebar_w + 1, start_y + 3, main_w,
                C.dim .. "   (No tasks found in this view. Press [a] to add a new task)" .. C.reset))
            for r = 4, max_visible_rows + 2 do
                table.insert(out, draw_box_row(sidebar_w + 1, start_y + r, main_w, ""))
            end
        else
            for r = 1, max_visible_rows do
                local item_idx = scroll_offset + r
                local t = visible_tasks[item_idx]
                local row_y = start_y + 2 + r
                if t then
                    local is_sel = (item_idx == sel_idx) and (active_pane == "tasks")
                    local status_sym = t.done and C.done_chk or C.pending_chk
                    local prio_sym = render_priority(t.priority)
                    local tag_sym = render_tag(t.category)
                    local due_str = t.due or "None"

                    local title_display = t.title
                    if t.done then
                        title_display = C.dim .. C.strike .. title_display .. C.reset
                    end

                    local line_content
                    if is_sel then
                        line_content = string.format("%s▶ %s %s %s %-32s %-10s%s",
                            C.sel_bg, status_sym, prio_sym, tag_sym, title_display, due_str, C.reset)
                    else
                        line_content = string.format("  %s %s %s %-32s %-10s",
                            status_sym, prio_sym, tag_sym, title_display, due_str)
                    end
                    table.insert(out, draw_box_row(sidebar_w + 1, row_y, main_w, line_content))
                else
                    table.insert(out, draw_box_row(sidebar_w + 1, row_y, main_w, ""))
                end
            end
        end

        -- 5. Right Bottom Pane: Selected Task Inspector / Details
        local detail_y = start_y + list_h
        draw_pane(out, sidebar_w + 1, detail_y, main_w, detail_h, "3. Task Inspector", false)

        local cur_task = visible_tasks[sel_idx]
        if cur_task then
            local status_text = cur_task.done and (C.bold .. C.msg_success .. "Completed ✔" .. C.reset)
                                              or (C.bold .. C.msg_warn .. "Pending Incomplete [ ]" .. C.reset)
            local prio_text = render_priority(cur_task.priority)
            local tag_text  = render_tag(cur_task.category)

            table.insert(out, draw_box_row(sidebar_w + 1, detail_y + 1, main_w,
                string.format("  %sTitle:%s %s%s%s", C.bold, C.reset, C.bold, cur_task.title, C.reset)))
            table.insert(out, draw_box_row(sidebar_w + 1, detail_y + 2, main_w,
                string.format("  %sStatus:%s %s  │  %sPriority:%s %s  │  %sTag:%s %s  │  %sDue:%s %s",
                    C.dim, C.reset, status_text,
                    C.dim, C.reset, prio_text,
                    C.dim, C.reset, tag_text,
                    C.dim, C.reset, cur_task.due or "None")))

            local notes = cur_task.notes or ""
            if notes == "" then notes = "(No extended notes. Press [e] to edit/add notes)" end
            table.insert(out, draw_box_row(sidebar_w + 1, detail_y + 3, main_w,
                string.format("  %sNotes:%s %s", C.dim, C.reset, notes)))

            local meta_str = string.format("  %sCreated:%s %s", C.dim, C.reset, cur_task.created_at or "N/A")
            if cur_task.completed_at then
                meta_str = meta_str .. string.format("  │  %sCompleted:%s %s", C.dim, C.reset, cur_task.completed_at)
            end
            table.insert(out, draw_box_row(sidebar_w + 1, detail_y + 4, main_w, meta_str))
        else
            table.insert(out, draw_box_row(sidebar_w + 1, detail_y + 1, main_w, C.dim .. "  (No task selected)" .. C.reset))
            for dr = 2, detail_h - 2 do
                table.insert(out, draw_box_row(sidebar_w + 1, detail_y + dr, main_w, ""))
            end
        end

        -- 6. Bottom Status & Message Bar
        local footer_y = term_h
        local msg_part = string.format(" %s%s%s", status_color, status_msg, C.reset)
        local key_hints = " [Space] Toggle  [a] Add  [e] Edit  [d] Delete  [p] Prio  [t] Tag  [?] Help  [q] Quit "
        local f_fill = math.max(0, term_w - visual_len(msg_part) - visual_len(key_hints))

        table.insert(out, string.format("\27[%d;1H%s%s%s\27[0m",
            footer_y, msg_part, string.rep(" ", f_fill), C.dim .. key_hints .. C.reset))

        -- 7. Modal Dialog Overlay (Add, Edit, Delete, Search, Help)
        if modal then
            local mw = math.min(68, term_w - 6)
            local mh = (modal == "help") and math.min(18, term_h - 4) or 10
            local mx = math.floor((term_w - mw) / 2)
            local my = math.floor((term_h - mh) / 2)

            -- Dim background outline / frame
            table.insert(out, string.format("\27[%d;%dH%s%s╭%s╮%s",
                my, mx, C.modal_bg, C.modal_border, string.rep("─", mw - 2), C.reset))
            for row = 1, mh - 2 do
                table.insert(out, string.format("\27[%d;%dH%s%s│%s│%s",
                    my + row, mx, C.modal_bg, C.modal_border, string.rep(" ", mw - 2), C.reset))
            end
            table.insert(out, string.format("\27[%d;%dH%s%s╰%s╯%s",
                my + mh - 1, mx, C.modal_bg, C.modal_border, string.rep("─", mw - 2), C.reset))

            local function modal_row(ry, str)
                local clr = truncate(str, mw - 4)
                local pad = string.rep(" ", math.max(0, mw - 4 - visual_len(clr)))
                table.insert(out, string.format("\27[%d;%dH%s %s%s %s", my + ry, mx + 1, C.modal_bg, clr, pad, C.reset))
            end

            if modal == "add" or modal == "edit" then
                local m_title = (modal == "add") and " ✨ Add New Task " or " ✏️ Edit Task "
                modal_row(0, C.modal_title .. pad_string(m_title, mw - 4, "center") .. C.reset)
                modal_row(1, "")

                local f1_cur = (modal_input.field == 1) and "▶ " or "  "
                local f2_cur = (modal_input.field == 2) and "▶ " or "  "
                local f3_cur = (modal_input.field == 3) and "▶ " or "  "
                local f4_cur = (modal_input.field == 4) and "▶ " or "  "

                modal_row(2, string.format("%s%sTitle:%s %s%s", f1_cur, C.bold, C.reset, modal_input.title, (modal_input.field == 1 and " ▎" or "")))
                modal_row(3, string.format("%s%sNotes:%s %s%s", f2_cur, C.bold, C.reset, modal_input.notes, (modal_input.field == 2 and " ▎" or "")))
                modal_row(4, string.format("%s%sPriority:%s %s  %s", f3_cur, C.bold, C.reset, render_priority(modal_input.priority), C.dim .. "(Press 1:High, 2:Med, 3:Low)" .. C.reset))
                modal_row(5, string.format("%s%sTag:%s %s  %s", f4_cur, C.bold, C.reset, render_tag(modal_input.category), C.dim .. "(Press 1:Dev, 2:Work, 3:Personal, 4:Study)" .. C.reset))
                modal_row(6, "")
                modal_row(7, C.dim .. " [Tab] Next field  [Enter] Save Task  [Esc] Cancel" .. C.reset)

            elseif modal == "delete" then
                local m_title = " ⚠️ Delete Task Confirmation "
                modal_row(0, C.modal_title .. pad_string(m_title, mw - 4, "center") .. C.reset)
                modal_row(2, pad_string("Are you sure you want to permanently delete this task?", mw - 4, "center"))
                if cur_task then
                    modal_row(4, pad_string(C.bold .. "\"" .. cur_task.title .. "\"" .. C.reset, mw - 4, "center"))
                end
                modal_row(6, pad_string(C.prio_high .. " [y] Confirm Delete " .. C.reset .. "   " .. C.dim .. "[n/Esc] Cancel" .. C.reset, mw - 4, "center"))

            elseif modal == "search" then
                local m_title = " 🔍 Live Search & Filter "
                modal_row(0, C.modal_title .. pad_string(m_title, mw - 4, "center") .. C.reset)
                modal_row(2, " Type search term (case-insensitive title/notes/tag):")
                modal_row(4, " ▶ " .. C.bold .. C.msg_info .. search_query .. " ▎" .. C.reset)
                modal_row(6, C.dim .. " [Enter] Apply Filter   [Backspace] Clear   [Esc] Reset Filter" .. C.reset)

            elseif modal == "help" then
                local m_title = " ⌨️ TODO TUI Keybindings Cheat Sheet "
                modal_row(0, C.modal_title .. pad_string(m_title, mw - 4, "center") .. C.reset)
                modal_row(2, " Navigation:")
                modal_row(3, "   ↑ / ↓ or k / j     : Navigate tasks in list")
                modal_row(4, "   Tab                : Switch active pane (Views <-> Tasks)")
                modal_row(5, "   1 .. 8             : Quick-jump to view/tag in sidebar")
                modal_row(6, " Task Actions:")
                modal_row(7, "   Space / Enter      : Toggle completed / active status [✔]")
                modal_row(8, "   a                  : Add new task (opens popup modal)")
                modal_row(9, "   e                  : Edit current task title & notes")
                modal_row(10, "   d / x              : Delete current task with confirmation")
                modal_row(11, "   p                  : Quick-cycle priority (High -> Med -> Low)")
                modal_row(12, "   t                  : Quick-cycle category tag (Dev, Work, ...)")
                modal_row(13, "   J / K              : Move current task down / up (reorder)")
                modal_row(14, "   /                  : Live search filter")
                modal_row(15, "   c                  : Clean / purge completed tasks")
                modal_row(16, C.dim .. " Press [Esc] or [?] to close this help dialog" .. C.reset)
            end
        end

        io.write(table.concat(out))
        io.flush()
    end

    -- Initial Render
    render()
    if is_snapshot then return end

    -- Interactive Event Loop
    local running = true
    while running do
        local k = read_key(50)
        if k then
            if modal then
                -- Handle Modal Input
                if k == "ESC" then
                    modal = nil
                    status_msg = "Modal cancelled."
                    status_color = C.msg_warn
                elseif modal == "help" then
                    if k == "ESC" or k == "?" or k == "q" or k == "ENTER" or k == "SPACE" then
                        modal = nil
                    end
                elseif modal == "delete" then
                    if k == "y" or k == "Y" then
                        local visible_tasks = get_visible_tasks()
                        local target = visible_tasks[sel_idx]
                        if target then
                            for idx, t in ipairs(tasks) do
                                if t.id == target.id then
                                    table.remove(tasks, idx)
                                    break
                                end
                            end
                            save_tasks(tasks)
                            status_msg = string.format("Deleted task: %q", target.title)
                            status_color = C.msg_warn
                            if sel_idx > 1 then sel_idx = sel_idx - 1 end
                        end
                        modal = nil
                    elseif k == "n" or k == "N" or k == "ESC" then
                        modal = nil
                        status_msg = "Delete cancelled."
                    end
                elseif modal == "search" then
                    if k == "ENTER" or k == "ESC" then
                        modal = nil
                        status_msg = (search_query ~= "") and ("Filter applied: " .. search_query) or "Filter cleared."
                        status_color = C.msg_info
                    elseif k == "BACKSPACE" then
                        if #search_query > 0 then
                            search_query = search_query:sub(1, -2)
                        end
                    elseif #k == 1 and k:byte() >= 32 and k:byte() <= 126 then
                        search_query = search_query .. k
                    end
                elseif modal == "add" or modal == "edit" then
                    if k == "TAB" or k == "DOWN" then
                        modal_input.field = (modal_input.field % 4) + 1
                    elseif k == "UP" then
                        modal_input.field = (modal_input.field == 1) and 4 or (modal_input.field - 1)
                    elseif k == "ENTER" then
                        if #modal_input.title:gsub("%s+", "") > 0 then
                            if modal == "add" then
                                local new_id = 1
                                for _, t in ipairs(tasks) do if t.id >= new_id then new_id = t.id + 1 end end
                                table.insert(tasks, 1, {
                                    id = new_id,
                                    title = modal_input.title,
                                    notes = modal_input.notes,
                                    done = false,
                                    priority = modal_input.priority,
                                    category = modal_input.category,
                                    due = "Today",
                                    created_at = os.date("%Y-%m-%d %H:%M")
                                })
                                status_msg = string.format("Added task: %q", modal_input.title)
                                status_color = C.msg_success
                                sel_idx = 1
                            else
                                local visible_tasks = get_visible_tasks()
                                local target = visible_tasks[sel_idx]
                                if target then
                                    target.title = modal_input.title
                                    target.notes = modal_input.notes
                                    target.priority = modal_input.priority
                                    target.category = modal_input.category
                                    status_msg = string.format("Updated task: %q", target.title)
                                    status_color = C.msg_success
                                end
                            end
                            save_tasks(tasks)
                            modal = nil
                        else
                            status_msg = "Task title cannot be empty!"
                            status_color = C.msg_warn
                        end
                    elseif modal_input.field == 1 then
                        -- Typing in Title field
                        if k == "BACKSPACE" then
                            if #modal_input.title > 0 then modal_input.title = modal_input.title:sub(1, -2) end
                        elseif #k == 1 and k:byte() >= 32 and k:byte() <= 126 then
                            modal_input.title = modal_input.title .. k
                        end
                    elseif modal_input.field == 2 then
                        -- Typing in Notes field
                        if k == "BACKSPACE" then
                            if #modal_input.notes > 0 then modal_input.notes = modal_input.notes:sub(1, -2) end
                        elseif #k == 1 and k:byte() >= 32 and k:byte() <= 126 then
                            modal_input.notes = modal_input.notes .. k
                        end
                    elseif modal_input.field == 3 then
                        -- Priority picker
                        if k == "1" then modal_input.priority = "high"
                        elseif k == "2" then modal_input.priority = "med"
                        elseif k == "3" then modal_input.priority = "low"
                        elseif k == "p" or k == "SPACE" then
                            local cycle = { high = "med", med = "low", low = "high" }
                            modal_input.priority = cycle[modal_input.priority] or "high"
                        end
                    elseif modal_input.field == 4 then
                        -- Category picker
                        if k == "1" then modal_input.category = "Dev"
                        elseif k == "2" then modal_input.category = "Work"
                        elseif k == "3" then modal_input.category = "Personal"
                        elseif k == "4" then modal_input.category = "Study"
                        elseif k == "5" then modal_input.category = "General"
                        elseif k == "t" or k == "SPACE" then
                            local cat_cycle = { Dev = "Work", Work = "Personal", Personal = "Study", Study = "General", General = "Dev" }
                            modal_input.category = cat_cycle[modal_input.category] or "Dev"
                        end
                    end
                end
            else
                -- Normal TUI Navigation & Actions
                if k == "q" or k == "CTRL_C" then
                    running = false
                elseif k == "?" or k == "h" then
                    modal = "help"
                elseif k == "TAB" then
                    active_pane = (active_pane == "sidebar") and "tasks" or "sidebar"
                elseif k == "UP" or k == "k" then
                    if active_pane == "sidebar" then
                        cur_view_idx = (cur_view_idx > 1) and (cur_view_idx - 1) or #VIEWS
                        sel_idx = 1
                    else
                        sel_idx = math.max(1, sel_idx - 1)
                    end
                elseif k == "DOWN" or k == "j" then
                    if active_pane == "sidebar" then
                        cur_view_idx = (cur_view_idx < #VIEWS) and (cur_view_idx + 1) or 1
                        sel_idx = 1
                    else
                        local visible_tasks = get_visible_tasks()
                        sel_idx = math.min(#visible_tasks, sel_idx + 1)
                    end
                elseif k == "PAGE_UP" then
                    sel_idx = math.max(1, sel_idx - 5)
                elseif k == "PAGE_DOWN" then
                    local visible_tasks = get_visible_tasks()
                    sel_idx = math.min(#visible_tasks, sel_idx + 5)
                elseif k == "HOME" or k == "g" then
                    sel_idx = 1
                elseif k == "END" or k == "G" then
                    local visible_tasks = get_visible_tasks()
                    sel_idx = math.max(1, #visible_tasks)
                elseif k >= "1" and k <= "8" then
                    local v_idx = tonumber(k)
                    if v_idx and v_idx >= 1 and v_idx <= #VIEWS then
                        cur_view_idx = v_idx
                        sel_idx = 1
                        status_msg = "Switched view to " .. VIEWS[v_idx].label
                        status_color = C.msg_info
                    end
                elseif k == "SPACE" or k == "ENTER" then
                    local visible_tasks = get_visible_tasks()
                    local t = visible_tasks[sel_idx]
                    if t then
                        t.done = not t.done
                        if t.done then
                            t.completed_at = os.date("%Y-%m-%d %H:%M")
                            status_msg = "Task completed: " .. t.title
                            status_color = C.msg_success
                        else
                            t.completed_at = nil
                            status_msg = "Task marked incomplete: " .. t.title
                            status_color = C.msg_warn
                        end
                        save_tasks(tasks)
                    end
                elseif k == "a" then
                    modal = "add"
                    modal_input = { title = "", notes = "", priority = "high", category = "Dev", field = 1 }
                elseif k == "e" then
                    local visible_tasks = get_visible_tasks()
                    local t = visible_tasks[sel_idx]
                    if t then
                        modal = "edit"
                        modal_input = {
                            title = t.title or "",
                            notes = t.notes or "",
                            priority = t.priority or "high",
                            category = t.category or "Dev",
                            field = 1
                        }
                    else
                        status_msg = "No task selected to edit."
                        status_color = C.msg_warn
                    end
                elseif k == "d" or k == "x" then
                    local visible_tasks = get_visible_tasks()
                    if visible_tasks[sel_idx] then
                        modal = "delete"
                    else
                        status_msg = "No task selected to delete."
                    end
                elseif k == "p" then
                    local visible_tasks = get_visible_tasks()
                    local t = visible_tasks[sel_idx]
                    if t then
                        local cycle = { high = "med", med = "low", low = "high" }
                        t.priority = cycle[t.priority] or "high"
                        save_tasks(tasks)
                        status_msg = string.format("Priority changed to %s for %q", t.priority:upper(), t.title)
                        status_color = C.msg_info
                    end
                elseif k == "t" then
                    local visible_tasks = get_visible_tasks()
                    local t = visible_tasks[sel_idx]
                    if t then
                        local cat_cycle = { Dev = "Work", Work = "Personal", Personal = "Study", Study = "General", General = "Dev" }
                        t.category = cat_cycle[t.category] or "Dev"
                        save_tasks(tasks)
                        status_msg = string.format("Category tag set to [%s] for %q", t.category, t.title)
                        status_color = C.msg_info
                    end
                elseif k == "J" then
                    -- Reorder move down
                    local visible_tasks = get_visible_tasks()
                    local t = visible_tasks[sel_idx]
                    if t and sel_idx < #visible_tasks then
                        local target_idx
                        for idx, item in ipairs(tasks) do
                            if item.id == t.id then target_idx = idx; break end
                        end
                        if target_idx and target_idx < #tasks then
                            tasks[target_idx], tasks[target_idx + 1] = tasks[target_idx + 1], tasks[target_idx]
                            save_tasks(tasks)
                            sel_idx = sel_idx + 1
                            status_msg = "Moved task down."
                        end
                    end
                elseif k == "K" then
                    -- Reorder move up
                    local visible_tasks = get_visible_tasks()
                    local t = visible_tasks[sel_idx]
                    if t and sel_idx > 1 then
                        local target_idx
                        for idx, item in ipairs(tasks) do
                            if item.id == t.id then target_idx = idx; break end
                        end
                        if target_idx and target_idx > 1 then
                            tasks[target_idx], tasks[target_idx - 1] = tasks[target_idx - 1], tasks[target_idx]
                            save_tasks(tasks)
                            sel_idx = sel_idx - 1
                            status_msg = "Moved task up."
                        end
                    end
                elseif k == "/" then
                    modal = "search"
                elseif k == "c" then
                    local before = #tasks
                    local new_list = {}
                    for _, t in ipairs(tasks) do
                        if not t.done then table.insert(new_list, t) end
                    end
                    local cleared = before - #new_list
                    if cleared > 0 then
                        tasks = new_list
                        save_tasks(tasks)
                        sel_idx = 1
                        status_msg = string.format("Purged %d completed task(s).", cleared)
                        status_color = C.msg_warn
                    else
                        status_msg = "No completed tasks to purge."
                        status_color = C.msg_info
                    end
                elseif k == "r" then
                    tasks = load_tasks()
                    status_msg = "Reloaded tasks from disk."
                    status_color = C.msg_info
                end
            end
            render()
        end
    end

    disable_raw_mode()
    print("\n\27[1;36mExited Todo-TUI. Tasks saved to " .. DB_FILE .. ". Goodbye!\27[0m\n")
end

-- =========================================================================
-- 6. CLI Command Mode Handler (--list, --add, --done, --help)
-- =========================================================================
local function main()
    local arg1 = arg and arg[1]
    if arg1 == "--help" or arg1 == "-h" then
        print([[
Todo-TUI - Terminal Task Manager (LuaJIT FFI Engine)

Usage:
    luajit todo_tui.lua                 Launch interactive TUI
    luajit todo_tui.lua --list          List all tasks
    luajit todo_tui.lua --add "Title" [prio: high|med|low] [tag: Dev|Work|Personal|Study]
    luajit todo_tui.lua --done <id>     Mark task ID completed
    luajit todo_tui.lua --help          Show this help message
]])
        return
    elseif arg1 == "--list" or arg1 == "-l" then
        local tasks = load_tasks()
        print(string.format("\n=== TODO TASKS (%d items) ===", #tasks))
        for _, t in ipairs(tasks) do
            local st = t.done and "[✔]" or "[ ]"
            print(string.format(" %2d. %s [%-4s] [%-8s] %s (Due: %s)",
                t.id, st, t.priority:upper(), t.category, t.title, t.due or "None"))
        end
        print("")
        return
    elseif arg1 == "--add" then
        local title = arg[2]
        if not title or #title == 0 then
            print("Error: Missing task title. Example: luajit todo_tui.lua --add \"Task name\"")
            return
        end
        local prio = (arg[3] or "high"):lower()
        local cat = arg[4] or "Dev"
        local tasks = load_tasks()
        local new_id = 1
        for _, t in ipairs(tasks) do if t.id >= new_id then new_id = t.id + 1 end end
        table.insert(tasks, 1, {
            id = new_id,
            title = title,
            notes = "",
            done = false,
            priority = prio,
            category = cat,
            due = "Today",
            created_at = os.date("%Y-%m-%d %H:%M")
        })
        save_tasks(tasks)
        print(string.format("✔ Added task #%d: %q [%s / %s]", new_id, title, prio:upper(), cat))
        return
    elseif arg1 == "--done" then
        local id_num = tonumber(arg[2])
        if not id_num then
            print("Error: Missing task ID. Example: luajit todo_tui.lua --done 2")
            return
        end
        local tasks = load_tasks()
        local found = false
        for _, t in ipairs(tasks) do
            if t.id == id_num then
                t.done = true
                t.completed_at = os.date("%Y-%m-%d %H:%M")
                found = true
                print(string.format("✔ Marked task #%d completed: %q", id_num, t.title))
                break
            end
        end
        if found then
            save_tasks(tasks)
        else
            print("Error: Task ID " .. id_num .. " not found.")
        end
        return
    end

    -- Run interactive TUI safely
    local is_snapshot = (arg1 == "--snapshot" or arg1 == "--no-interactive")
    local ok, err = pcall(run_tui, is_snapshot)
    disable_raw_mode()
    if not ok then
        io.stderr:write("\n[TUI Error]: " .. tostring(err) .. "\n")
    end
end

main()
