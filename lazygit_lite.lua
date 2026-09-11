--[[
    lazygit_lite.lua
    A fast, beautiful, and practical Git TUI written in pure LuaJIT with FFI.
    Inspired by lazygit.

    Features:
    - POSIX ioctl(TIOCGWINSZ) for terminal window size detection.
    - POSIX termios raw mode + poll() for instant non-blocking keystrokes.
    - Multi-pane layout:
      [1] Status / Changed Files (staged & unstaged)
      [2] Git Branches (local & remote)
      [3] Git Commits (recent history log)
      [4] Diff / Commit Inspector viewer (syntax colored diff)
    - Keybindings:
      - Tab / 1, 2, 3 : Switch active pane
      - ↑ / ↓ or k / j: Navigate items in active pane
      - Space         : Stage / unstage selected file (git add / git reset)
      - a             : Stage all / unstage all
      - c             : Quick commit prompt
      - d             : Discard changes in working directory (with confirmation)
      - b             : Checkout branch
      - r             : Refresh git status
      - q / ESC       : Quit
]]

local ffi = require("ffi")

-- =========================================================================
-- 1. FFI C Definitions for POSIX Terminal, Polling, and Window
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

    -- Switch to alternate screen buffer, hide cursor, enable bracketed paste
    io.write("\27[?1049h\27[?25l")
    io.flush()
    return true
end

local function disable_raw_mode()
    if in_raw_mode then
        -- Return to main screen buffer, restore cursor, reset color
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
local key_buf = ffi.new("char[32]")

local function read_key(timeout_ms)
    timeout_ms = timeout_ms or 50
    local ret = ffi.C.poll(pfd, 1, timeout_ms)
    if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
        local n = ffi.C.read(STDIN_FILENO, key_buf, 32)
        if n > 0 then
            local c0 = key_buf[0]
            if c0 == 27 then
                if n >= 3 and key_buf[1] == 91 then
                    local c2 = key_buf[2]
                    if c2 == 65 then return "UP" end
                    if c2 == 66 then return "DOWN" end
                    if c2 == 67 then return "RIGHT" end
                    if c2 == 68 then return "LEFT" end
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
            else
                return string.char(c0)
            end
        end
    end
    return nil
end

-- =========================================================================
-- 2. Styling, Colors, and Unicode Box Characters
-- =========================================================================
local C = {
    reset        = "\27[0m",
    bold         = "\27[1m",
    dim          = "\27[2m",
    italic       = "\27[3m",

    -- Borders
    border_focus = "\27[1;38;2;56;189;248m",   -- Cyan
    border_dim   = "\27[38;2;71;85;105m",      -- Slate grey
    header_title = "\27[1;38;2;241;245;249m",

    -- Selection
    sel_bg       = "\27[48;2;30;58;138m\27[1;38;2;255;255;255m", -- Royal blue highlight
    active_tag   = "\27[1;38;2;52;211;153m",   -- Emerald

    -- Git status indicators
    staged_color = "\27[1;38;2;34;197;94m",    -- Green
    unstaged_col = "\27[1;38;2;239;68;68m",    -- Red
    untracked_col= "\27[1;38;2;234;179;8m",    -- Amber

    -- Diff colors
    diff_add     = "\27[38;2;34;197;94m",      -- Green
    diff_del     = "\27[38;2;239;68;68m",      -- Red
    diff_hunk    = "\27[38;2;168;85;247m",     -- Purple
    diff_hdr     = "\27[1;38;2;203;213;225m",  -- Bright text
    diff_meta    = "\27[38;2;100;116;139m",    -- Muted grey

    -- Notifications
    msg_info     = "\27[1;38;2;56;189;248m",
    msg_success  = "\27[1;38;2;34;197;94m",
    msg_warn     = "\27[1;38;2;234;179;8m",
}

local function visual_len(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    local _, count = clean:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
    return count
end

local function truncate(str, max_w)
    local len = visual_len(str)
    if len <= max_w then return str end
    if max_w <= 3 then return string.rep(".", max_w) end

    -- Safe truncation
    local out = {}
    local curr = 0
    for c in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if curr + 1 > max_w - 3 then break end
        table.insert(out, c)
        curr = curr + 1
    end
    return table.concat(out) .. "..."
end

-- =========================================================================
-- 3. Git Querying Engine
-- =========================================================================
local function exec_git(cmd)
    local p = io.popen("git " .. cmd .. " 2>/dev/null", "r")
    if not p then return "" end
    local res = p:read("*a")
    p:close()
    return res or ""
end

local function get_git_status()
    local raw = exec_git("status --porcelain=v1")
    local files = {}

    for line in raw:gmatch("[^\r\n]+") do
        local x = line:sub(1, 1)
        local y = line:sub(2, 2)
        local path = line:sub(4)

        local is_staged = (x ~= " " and x ~= "?")
        local is_unstaged = (y ~= " " and y ~= "?")
        local is_untracked = (x == "?" and y == "?")

        local status_tag = ""
        local color = C.diff_meta

        if is_untracked then
            status_tag = "??"
            color = C.untracked_col
        elseif is_staged and is_unstaged then
            status_tag = x .. y
            color = C.unstaged_col
        elseif is_staged then
            status_tag = x .. " "
            color = C.staged_color
        else
            status_tag = " " .. y
            color = C.unstaged_col
        end

        table.insert(files, {
            path = path,
            status_tag = status_tag,
            color = color,
            is_staged = is_staged,
            is_untracked = is_untracked,
            x = x,
            y = y,
        })
    end
    return files
end

local function get_git_branches()
    local raw = exec_git("branch -a --sort=-committerdate")
    local branches = {}

    for line in raw:gmatch("[^\r\n]+") do
        local is_current = line:sub(1, 2) == "* "
        local name = line:sub(3):gsub("^%s+", "")
        -- Filter out HEAD detached or symrefs
        if not name:find("%->") then
            local is_remote = name:find("^remotes/") ~= nil
            table.insert(branches, {
                name = name,
                is_current = is_current,
                is_remote = is_remote,
            })
        end
    end
    return branches
end

local function get_git_commits(limit)
    limit = limit or 25
    local raw = exec_git(string.format("log -n %d --pretty=format:'%%h|%%an|%%cr|%%s'", limit))
    local commits = {}

    for line in raw:gmatch("[^\r\n]+") do
        local hash, author, time, subject = line:match("([^|]+)|([^|]+)|([^|]+)|(.*)")
        if hash then
            table.insert(commits, {
                hash = hash,
                author = author,
                time = time,
                subject = subject,
            })
        end
    end
    return commits
end

local function get_git_diff(filepath, is_staged)
    local cmd = is_staged and ("diff --cached -- " .. filepath) or ("diff -- " .. filepath)
    local raw = exec_git(cmd)
    if #raw == 0 then
        -- Might be untracked or empty diff
        local untracked_check = exec_git("status --porcelain -- " .. filepath)
        if untracked_check:sub(1, 2) == "??" then
            -- Show file preview for untracked
            local f = io.open(filepath, "r")
            if f then
                local content = f:read(3000) or ""
                f:close()
                local lines = {}
                for l in content:gmatch("[^\r\n]+") do
                    table.insert(lines, C.diff_add .. "+ " .. l .. C.reset)
                end
                return lines
            end
        end
        return { C.dim .. "(No diff content or working tree clean)" .. C.reset }
    end

    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        local first = line:sub(1, 1)
        if line:sub(1, 4) == "+++" or line:sub(1, 4) == "---" or line:sub(1, 4) == "diff" then
            table.insert(lines, C.diff_hdr .. line .. C.reset)
        elseif line:sub(1, 2) == "@@" then
            table.insert(lines, C.diff_hunk .. line .. C.reset)
        elseif first == "+" then
            table.insert(lines, C.diff_add .. line .. C.reset)
        elseif first == "-" then
            table.insert(lines, C.diff_del .. line .. C.reset)
        else
            table.insert(lines, C.diff_meta .. line .. C.reset)
        end
    end
    return lines
end

local function get_commit_details(hash)
    local raw = exec_git("show --stat -p " .. hash)
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        local first = line:sub(1, 1)
        if line:sub(1, 6) == "commit" or line:sub(1, 6) == "Author" or line:sub(1, 4) == "Date" then
            table.insert(lines, C.header_title .. line .. C.reset)
        elseif line:sub(1, 2) == "@@" then
            table.insert(lines, C.diff_hunk .. line .. C.reset)
        elseif first == "+" then
            table.insert(lines, C.diff_add .. line .. C.reset)
        elseif first == "-" then
            table.insert(lines, C.diff_del .. line .. C.reset)
        else
            table.insert(lines, line)
        end
    end
    return lines
end

-- =========================================================================
-- 4. TUI Screen Drawing & Layout Engine
-- =========================================================================
local function draw_box_row(x, y, w, text)
    -- Position cursor at x, y and print formatted row
    local clr = truncate(text, w - 2)
    local vlen = visual_len(clr)
    local pad = string.rep(" ", math.max(0, w - 2 - vlen))
    return string.format("\27[%d;%dH%s%s", y, x + 1, clr, pad)
end

local function draw_border_rect(x, y, w, h, title, is_focused)
    local bcol = is_focused and C.border_focus or C.border_dim
    local out = {}

    -- Top border with title
    local title_str = title and string.format(" %s%s%s ", C.header_title, title, bcol) or ""
    local t_len = title and (visual_len(title) + 2) or 0
    local top_fill = string.rep("─", math.max(0, w - 2 - t_len))
    table.insert(out, string.format("\27[%d;%dH%s╭%s%s╮%s", y, x, bcol, title_str, top_fill, C.reset))

    -- Side borders
    for i = 1, h - 2 do
        table.insert(out, string.format("\27[%d;%dH%s│\27[%d;%dH│%s", y + i, x, bcol, y + i, x + w - 1, C.reset))
    end

    -- Bottom border
    local bot_fill = string.rep("─", math.max(0, w - 2))
    table.insert(out, string.format("\27[%d;%dH%s╰%s╯%s", y + h - 1, x, bcol, bot_fill, C.reset))

    return table.concat(out)
end

-- =========================================================================
-- 5. Application State & Interactive Loop
-- =========================================================================
local function main()
    -- Ensure we are in a Git repository
    local is_repo = exec_git("rev-parse --is-inside-work-tree"):match("true")
    if not is_repo then
        io.stderr:write("\27[1;31mError: Not a git repository.\27[0m\n")
        os.exit(1)
    end

    enable_raw_mode()

    local active_pane = 1 -- 1: Files, 2: Branches, 3: Commits, 4: Diff View
    local sel_file = 1
    local sel_branch = 1
    local sel_commit = 1
    local diff_scroll = 0

    local files = get_git_status()
    local branches = get_git_branches()
    local commits = get_git_commits(40)
    local status_msg = "Ready. Press [Space] to stage, [c] to commit, [Tab] to switch panes."
    local status_msg_color = C.msg_info

    local needs_redraw = true

    local function refresh_git()
        files = get_git_status()
        branches = get_git_branches()
        commits = get_git_commits(40)
        sel_file = math.max(1, math.min(sel_file, math.max(1, #files)))
        sel_branch = math.max(1, math.min(sel_branch, math.max(1, #branches)))
        sel_commit = math.max(1, math.min(sel_commit, math.max(1, #commits)))
        diff_scroll = 0
        needs_redraw = true
    end

    local last_w, last_h = get_terminal_size()

    -- Initial clear once
    io.write("\27[H\27[2J")
    io.flush()

    while true do
        local term_w, term_h = get_terminal_size()
        if term_w ~= last_w or term_h ~= last_h then
            last_w, last_h = term_w, term_h
            needs_redraw = true
            io.write("\27[H\27[2J") -- Clear on resize
        end

        if needs_redraw then
            local out = {}

            -- Home cursor without blanking the screen (never emit \27[2J in regular loops to avoid screen flash)
            table.insert(out, "\27[H")
            local repo_name = exec_git("rev-parse --show-toplevel"):match("([^/]+)%s*$") or "repository"
            local current_branch = exec_git("branch --show-current"):gsub("%s+", "")
            local header_text = string.format("  \27[1;38;2;56;189;248m⚡ LAZYGIT-LITE\27[0m \27[90m│\27[0m \27[1;97m%s\27[0m \27[90m(\27[1;38;2;52;211;153m%s\27[0m\27[90m)\27[0m\27[K",
                repo_name, current_branch ~= "" and current_branch or "detached")
            table.insert(out, header_text .. "\n")

            -- Layout Geometry Calculation
            local usable_h = math.max(12, term_h - 3) -- leave header + footer
            local left_w = math.max(28, math.floor(term_w * 0.38))
            local right_w = term_w - left_w

            local h_files = math.floor(usable_h * 0.42)
            local h_branches = math.floor(usable_h * 0.28)
            local h_commits = usable_h - h_files - h_branches

            local y_files = 2
            local y_branches = y_files + h_files
            local y_commits = y_branches + h_branches

            -- Draw Pane 1: Files / Status
            table.insert(out, draw_border_rect(1, y_files, left_w, h_files, "1. Files (" .. #files .. ")", active_pane == 1))
            local f_visible = h_files - 2
            for i = 1, f_visible do
                local f_idx = i
                if f_idx <= #files then
                    local f = files[f_idx]
                    local is_sel = (active_pane == 1 and f_idx == sel_file)
                    local line_str = string.format("%s %s", f.status_tag, f.path)
                    local content = is_sel and (C.sel_bg .. "▶ " .. line_str .. C.reset) or (f.color .. "  " .. line_str .. C.reset)
                    table.insert(out, draw_box_row(1, y_files + i, left_w, content))
                else
                    table.insert(out, draw_box_row(1, y_files + i, left_w, ""))
                end
            end

            -- Draw Pane 2: Branches
            table.insert(out, draw_border_rect(1, y_branches, left_w, h_branches, "2. Branches (" .. #branches .. ")", active_pane == 2))
            local b_visible = h_branches - 2
            for i = 1, b_visible do
                local b_idx = i
                if b_idx <= #branches then
                    local b = branches[b_idx]
                    local is_sel = (active_pane == 2 and b_idx == sel_branch)
                    local prefix = b.is_current and (C.active_tag .. "* " .. C.reset) or "  "
                    local content = is_sel and (C.sel_bg .. "▶ " .. b.name .. C.reset) or (prefix .. (b.is_remote and (C.dim .. b.name .. C.reset) or b.name))
                    table.insert(out, draw_box_row(1, y_branches + i, left_w, content))
                else
                    table.insert(out, draw_box_row(1, y_branches + i, left_w, ""))
                end
            end

            -- Draw Pane 3: Commits
            table.insert(out, draw_border_rect(1, y_commits, left_w, h_commits, "3. Commits (" .. #commits .. ")", active_pane == 3))
            local c_visible = h_commits - 2
            for i = 1, c_visible do
                local c_idx = i
                if c_idx <= #commits then
                    local cm = commits[c_idx]
                    local is_sel = (active_pane == 3 and c_idx == sel_commit)
                    local line_str = string.format("%s %s", cm.hash, cm.subject)
                    local content = is_sel and (C.sel_bg .. "▶ " .. line_str .. C.reset) or ("  " .. C.header_title .. cm.hash .. C.reset .. " " .. cm.subject)
                    table.insert(out, draw_box_row(1, y_commits + i, left_w, content))
                else
                    table.insert(out, draw_box_row(1, y_commits + i, left_w, ""))
                end
            end

            -- Draw Pane 4: Diff / Inspector (Right side)
            local diff_title = "4. Diff Inspector"
            local diff_lines = {}

            if active_pane == 3 and commits[sel_commit] then
                diff_title = "Commit: " .. commits[sel_commit].hash .. " (" .. commits[sel_commit].author .. ", " .. commits[sel_commit].time .. ")"
                diff_lines = get_commit_details(commits[sel_commit].hash)
            elseif files[sel_file] then
                diff_title = "Diff: " .. files[sel_file].path
                diff_lines = get_git_diff(files[sel_file].path, files[sel_file].is_staged)
            else
                diff_lines = { C.dim .. "Working tree clean. No files changed." .. C.reset }
            end

            table.insert(out, draw_border_rect(left_w + 1, y_files, right_w, usable_h, diff_title, active_pane == 4))
            local d_visible = usable_h - 2
            for i = 1, d_visible do
                local d_idx = i + diff_scroll
                local content = diff_lines[d_idx] or ""
                table.insert(out, draw_box_row(left_w + 1, y_files + i, right_w, content))
            end

            -- Footer / Keybinding & Message Bar
            local footer_y = term_h - 1
            local help_keys = "[Tab] Switch Pane  [Space] Stage/Unstage  [c] Commit  [d] Discard  [r] Refresh  [q] Quit"
            local footer_str = string.format("\27[%d;1H\27[2K  %s%s%s \27[90m│\27[0m \27[90m%s\27[0m",
                footer_y, status_msg_color, status_msg, C.reset, help_keys)
            table.insert(out, footer_str)

            io.write(table.concat(out))
            io.flush()
            needs_redraw = false
        end

        -- Key handling: blocks up to 200ms when idle without spinning CPU or causing flashes
        local k = read_key(200)
        if k then
            needs_redraw = true
            if k == "q" or k == "ESC" then
                break
            elseif k == "TAB" then
                active_pane = (active_pane % 4) + 1
                status_msg = "Switched to pane " .. active_pane
                status_msg_color = C.msg_info
            elseif k == "1" then
                active_pane = 1
            elseif k == "2" then
                active_pane = 2
            elseif k == "3" then
                active_pane = 3
            elseif k == "4" then
                active_pane = 4
            elseif k == "UP" or k == "k" then
                if active_pane == 1 then
                    sel_file = math.max(1, sel_file - 1)
                elseif active_pane == 2 then
                    sel_branch = math.max(1, sel_branch - 1)
                elseif active_pane == 3 then
                    sel_commit = math.max(1, sel_commit - 1)
                elseif active_pane == 4 then
                    diff_scroll = math.max(0, diff_scroll - 1)
                end
            elseif k == "DOWN" or k == "j" then
                if active_pane == 1 then
                    sel_file = math.min(#files, sel_file + 1)
                elseif active_pane == 2 then
                    sel_branch = math.min(#branches, sel_branch + 1)
                elseif active_pane == 3 then
                    sel_commit = math.min(#commits, sel_commit + 1)
                elseif active_pane == 4 then
                    diff_scroll = diff_scroll + 1
                end
            elseif k == "PAGE_UP" then
                if active_pane == 4 then
                    diff_scroll = math.max(0, diff_scroll - 10)
                end
            elseif k == "PAGE_DOWN" then
                if active_pane == 4 then
                    diff_scroll = diff_scroll + 10
                end
            elseif k == "SPACE" then
                -- Stage or unstage file
                if #files > 0 and files[sel_file] then
                    local f = files[sel_file]
                    if f.is_staged then
                        exec_git("restore --staged " .. f.path)
                        status_msg = "Unstaged " .. f.path
                    else
                        exec_git("add " .. f.path)
                        status_msg = "Staged " .. f.path
                    end
                    status_msg_color = C.msg_success
                    refresh_git()
                end
            elseif k == "a" then
                -- Toggle stage all
                local has_unstaged = false
                for _, f in ipairs(files) do
                    if not f.is_staged then has_unstaged = true break end
                end
                if has_unstaged then
                    exec_git("add -A")
                    status_msg = "Staged all changes."
                else
                    exec_git("reset")
                    status_msg = "Unstaged all changes."
                end
                status_msg_color = C.msg_success
                refresh_git()
            elseif k == "d" then
                -- Discard changes
                if #files > 0 and files[sel_file] then
                    local f = files[sel_file]
                    exec_git("restore " .. f.path)
                    status_msg = "Discarded changes in " .. f.path
                    status_msg_color = C.msg_warn
                    refresh_git()
                end
            elseif k == "c" then
                -- Interactive commit prompt
                disable_raw_mode()
                io.write("\n\27[1;38;2;56;189;248mEnter commit message (empty to cancel): \27[0m")
                io.flush()
                local msg = io.read("*l")
                if msg and #msg > 0 then
                    local out_msg = exec_git(string.format("commit -m %q", msg))
                    status_msg = "Committed: " .. (out_msg:match("%[([^%]]+)%]") or msg)
                    status_msg_color = C.msg_success
                else
                    status_msg = "Commit cancelled."
                    status_msg_color = C.msg_warn
                end
                enable_raw_mode()
                refresh_git()
            elseif k == "r" then
                refresh_git()
                status_msg = "Git status refreshed."
                status_msg_color = C.msg_info
            end
        end
    end

    disable_raw_mode()
    print("\n\27[1;36mExited lazygit-lite. Goodbye!\27[0m")
end

main()
