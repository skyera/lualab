#!/usr/bin/env luajit
local ffi = require('ffi')
local bit = require('bit')
local finder = require('ffi_duplicates')
local tui, json = finder.tui, require('json')
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end
local result = {
    groups = {},
    errors = { { path = 'bad\27path', message = 'Unreadable % file' } },
    files = 200,
    redundant_bytes = 0,
    skipped_links = 2,
}
for i = 1, 35 do
    local group = {
        size = i * 1024,
        paths = { '/group ' .. i .. '/文件-😀-' .. string.rep('long', 30), '/copy ' .. i },
    }
    result.groups[#result.groups + 1] = group
    result.redundant_bytes = result.redundant_bytes + group.size
end
local function validate_frame(frame, cols, rows)
    check(#frame == rows, 'renderer row count')
    for row, line in ipairs(frame) do
        check(not line:find('\27', 1, true), 'filename cannot inject terminal controls')
        check(tui.fit(line, cols - 1) == line, 'renderer clamps display cells')
        local painted = frame.paint[row]
        local stripped = painted:gsub('\27%[[%d;]+m', '')
        check(stripped == line, 'styling preserves every display cell')
        check(not stripped:find('\27', 1, true), 'painted rows contain only SGR controls')
        check(
            not painted:find('\27%[[%d;]+m') or painted:sub(-4) == '\27[0m',
            'colored rows restore the default style'
        )
    end
end
-- Run each renderer directly across empty/full, Unicode/control, and viewport boundaries.
for _, data in ipairs({
    result,
    { groups = {}, errors = {}, files = 0, redundant_bytes = 0, skipped_links = 0 },
}) do
    for _, size in ipairs({
        { 1, 1 },
        { 2, 2 },
        { 12, 4 },
        { 35, 6 },
        { 36, 5 },
        { 36, 6 },
        { 40, 12 },
        { 70, 6 },
        { 71, 6 },
        { 71, 5 },
        { 80, 24 },
        {
            120,
            35,
        },
    }) do
        local model = tui.model(data)
        model:clamp(size[1], size[2])
        for _, view in ipairs({ 'browse', 'details', 'errors', 'help' }) do
            model.view = view
            for _, pane in ipairs({ 'groups', 'files' }) do
                model.pane = pane
                local frame = tui.frame(model, size[1], size[2])
                validate_frame(frame, size[1], size[2])
                model.color = false
                local monochrome = tui.frame(model, size[1], size[2])
                validate_frame(monochrome, size[1], size[2])
                check(
                    table.concat(monochrome.paint) == table.concat(frame),
                    'monochrome retains borders and selection markers without SGR'
                )
                model.color = true
            end
        end
        for _, color in ipairs({ true, false }) do
            validate_frame(
                tui.render_progress(
                    { phase = 'Hashing', path = '中文\27\n', files = 0, color = color },
                    size[1],
                    size[2]
                ),
                size[1],
                size[2]
            )
        end
    end
end
local model = tui.model(result)
model:clamp(100, 12)
check(model:selected().size == 35 * 1024, 'TUI sorts by redundant bytes')
for _ = 1, 60 do
    model:key('DOWN')
end
check(
    model.group == 35
        and model.group >= model.group_scroll + 1
        and model.group <= model.group_scroll + 8,
    'last group visible'
)
model:key('HOME')
check(model.group == 1 and model.group_scroll == 0, 'home boundary')
model:key('PAGE_DOWN')
check(model.group == 9, 'page group movement')
model:key('TAB')
model:key('END')
check(model.file == 2 and model.pane == 'files', 'file pane navigation')
model:key('ENTER')
model:key('END')
local bottom = model.detail_scroll
check(
    bottom == math.max(0, #tui.detail_lines(model, tui.content_width(100, 12)) - 8),
    'details END uses bordered content width'
)
model:key('UP')
check(model.detail_scroll == math.max(0, bottom - 1), 'details scroll up after END')
model:key('ESC')
check(model.view == 'browse', 'details close')
model:key('?')
check(model.view == 'help', 'question mark opens help')
check(table.concat(tui.frame(model, 100, 12)):find('Help - keys', 1, true), 'help view rendered')
model:key('END')
local help_bottom = model.detail_scroll
model:key('UP')
check(model.detail_scroll == help_bottom - 1, 'help scrolls up after END')
model:key('?')
check(model.view == 'browse', 'question mark toggles help closed')
model:key('ENTER')
model:key('DOWN')
local previous_scroll = model.detail_scroll
model:key('?')
model:key('ESC')
check(
    model.view == 'details' and model.detail_scroll == previous_scroll,
    'help restores previous view and scroll'
)
model:key('ESC')
model:key('!')
check(model.view == 'errors', 'error view opens')
model:key('ESC')
model:key('TAB')
model:key('SPACE')
check(#model:export_result().groups == 1, 'selected group export')
model:key('DOWN')
model:key('SPACE')
check(#model:export_result().groups == 2, 'marked group export')
model:key('/')
for _, token in ipairs({ 'g', 'r', 'o', 'u', 'p', 'SPACE', '3', '5', 'BACKSPACE', '5' }) do
    model:key(token)
end
check(model.query == 'group 35', 'symbolic SPACE/BACKSPACE text input')
local echo = tui.frame(model, 100, 12)
check(echo[11]:find('group 35', 1, true) ~= nil, 'prompt echoes before filtering')
local prompt_diff = tui.diff(echo, tui.render_browse(tui.model(result), 100, 12))
check(not prompt_diff:find('\27[2J', 1, true), 'filter never clears screen')
model:filter()
model:clamp(100, 12)
check(#model.visible == 1, 'path filtering')
model:key('ESC')
model:filter()
check(model.query == '' and #model.visible == 35, 'ESC restores prior filter')
model:key('/')
model:key('中')
model:key('😀')
model:key('BACKSPACE')
check(model.query == '中', 'backspace removes full UTF-8 scalar')
model:key('ESC')
model:filter()
model:key('e')
model:key('SPACE')
model:key('中')
model:key('BACKSPACE')
model:key('BACKSPACE')
check(model.input == '', 'export backspace at zero')
for _, key in ipairs({ 'n', 'e', 'w', 'SPACE', 'f', 'i', 'l', 'e', '.', 'j', 's', 'o', 'n' }) do
    model:key(key)
end
local running, effect = model:key('ENTER')
check(
    running and effect.path == 'new file.json' and #effect.result.groups == 2,
    'export prompt token loop'
)
model:key('/')
model:key('x')
model:filter()
model:clamp(80, 24)
check(model.group == 0 and model.file == 0, 'empty selection invariant')
model:key('ENTER')
check(model.prompt == nil, 'filter submit')
model.marked = {}
model:key('e')
check(model.prompt == nil, 'empty export handled')
-- Decoder receives real fragmented terminal bytes, including UTF-8 split across reads.
local tiny = tui.model(result)
tiny:clamp(12, 4)
tiny:key('/')
tiny:key('x')
check(tui.frame(tiny, 12, 4)[4]:find('/x_', 1, true) ~= nil, 'small terminal prompt echoes')
local decode = tui.decoder()
check(#decode('\27[') == 0, 'partial arrow retained')
check(decode('A')[1] == 'UP', 'arrow decoded')
check(decode(' \127\r\t')[1] == 'SPACE', 'symbolic SPACE emitted')
check(#decode('\240\159') == 0, 'partial UTF-8 retained')
check(decode('\152\128')[1] == '😀', 'UTF-8 input reassembled')
check(#decode('\27') == 0 and decode('', true)[1] == 'ESC', 'standalone ESC flushed')
local full = decode('\27[6~\27[H\27[F\3', true)
check(table.concat(full, ',') == 'PAGE_DOWN,HOME,END,CTRL_C', 'navigation and Ctrl-C tokens')
local plain = tui.model(result)
plain:clamp(40, 12)
local first = tui.frame(plain, 40, 12)
plain:key('DOWN')
local second = tui.frame(plain, 40, 12)
local diff = tui.diff(second, first)
local _, count = diff:gsub('\27%[%d+;1H', '')
check(count == 2, 'local group movement changes only selection rows')
check(diff:sub(1, 8) == '\27[?2026h' and diff:sub(-8) == '\27[?2026l', 'atomic synchronized frame')
check(tui.diff(second, second) == '', 'unchanged frame emits nothing')
check(not diff:find('\27[2J', 1, true), 'movement never clears')
local styled = tui.model(result)
styled:clamp(100, 12)
local colored = tui.frame(styled, 100, 12)
check(colored[2]:find('┌', 1, true) and colored[2]:find('┬', 1, true), 'wide bordered panes')
check(colored.paint[3]:find('\27[1;97;44m', 1, true), 'active selection has a blue background')
styled:key('TAB')
local switched = tui.frame(styled, 100, 12)
check(table.concat(colored) == table.concat(switched), 'pane focus retains the text layout')
check(tui.diff(switched, colored) ~= '', 'style-only focus changes redraw')
local _, focus_rows = tui.diff(switched, colored):gsub('\27%[%d+;1H', '')
check(focus_rows == 2, 'focus updates only pane titles and selected cells')
styled.color = false
local uncolored = tui.frame(styled, 100, 12)
check(tui.diff(uncolored, switched) ~= '', 'color changes invalidate cached paint')
styled:key('SPACE')
check(tui.frame(styled, 100, 12)[11]:find('1 marked', 1, true), 'status reports marked groups')
for width = 0, 45 do
    for _, path in ipairs({
        '',
        'a',
        '/long/中文/文件-😀.txt',
        'C:\\photos\\backup\\image.jpg',
        '/bad\27[2J\n\255/path/last.txt',
    }) do
        local label = tui.ellipsize(path, width)
        check(tui.fit(label, width) == label, 'path elision respects display width')
        check(not label:find('\27', 1, true), 'elided paths cannot inject terminal controls')
    end
end
check(
    tui.ellipsize('/very/long/path/image.jpg', 12) == '…h/image.jpg',
    'elision keeps the basename and trailing path'
)
-- Actual export preserves existing files and uses the same standalone JSON schema.
local path = os.tmpname()
os.remove(path)
local ok, e = finder.export_file(path, result)
check(ok, e)
local file = assert(io.open(path, 'rb'))
local text = file:read('*a')
file:close()
check(#json.decode(text).groups == 35, 'actual exported JSON')
check(not finder.export_file(path, result), 'export refuses overwrite')
file = assert(io.open(path, 'rb'))
check(file:read('*a') == text, 'existing export unchanged')
file:close()
os.remove(path)
local candidate = path .. '-copy'
local payload = string.rep('\0\255data', 20000)
for _, name in ipairs({ path, candidate }) do
    local f = assert(io.open(name, 'wb'))
    assert(f:write(payload))
    assert(f:close())
end
for _, phase in ipairs({ 'Hashing candidates', 'Comparing candidates' }) do
    local cancelled = finder.scan({ path, candidate }, {
        progress = function(current, _, bytes)
            collectgarbage('collect')
            return not (current == phase and bytes > 0)
        end,
    })
    check(cancelled.cancelled and #cancelled.errors == 0, 'native cancellation during ' .. phase)
end
os.remove(path)
os.remove(candidate)
-- Runtime harness checks input dispatch, immediate echo, resize and protected cleanup.
local function terminal(batches)
    local term = { writes = {}, batch = 0, clock = 0, restored = false }
    function term:is_tty()
        return true
    end
    function term:now()
        self.clock = self.clock + 0.1
        return self.clock
    end
    function term:size()
        return self.batch < 3 and 80 or 40, 12
    end
    function term:write(text)
        self.writes[#self.writes + 1] = text
    end
    function term:enter()
        self.entered = true
    end
    function term:restore()
        self.restored = true
    end
    function term:keys(timeout)
        if timeout == 0 then
            return {}
        end
        self.batch = self.batch + 1
        return batches[self.batch] or { 'q' }
    end
    return term
end
local api = {
    scan = function(roots, options)
        assert(options.progress('Discovering', 'file', 0, result))
        return result
    end,
    export_file = function()
        return nil, 'permission denied'
    end,
}
local term = terminal({
    { '/' },
    { 'g', 'SPACE', '3' },
    { 'ESC' },
    { 'e', 'x', 'ENTER' },
    { '!', 'ESC', 'ENTER', 'ESC' },
    { 'q' },
})
check(tui.run(api, { '.' }, {}, term) == 0 and term.restored, 'runtime restores after normal exit')
check(
    table.concat(term.writes):find('permission denied', 1, true) ~= nil,
    'export errors visible in status'
)
term = terminal({ { 'q' } })
api.scan = function()
    error('injected scan failure')
end
local stderr = io.stderr
local errors = {}
io.stderr = {
    write = function(_, ...)
        for _, s in ipairs({ ... }) do
            errors[#errors + 1] = s
        end
    end,
}
local code = tui.run(api, { '.' }, {}, term)
io.stderr = stderr
check(code == 1 and term.restored, 'exception restores terminal')
check(table.concat(errors):find('injected scan failure', 1, true) ~= nil, 'runtime error surfaced')
term = terminal({})
function term:keys()
    return { 'q' }
end
api.scan = function(roots, options)
    check(options.progress('Hashing', 'a', 1, result) == false, 'progress cancellation')
    return { cancelled = true }
end
check(tui.run(api, { '.' }, {}, term) == 0 and term.restored, 'cancel scan restores terminal')
-- Windows console API double exercises mode lifecycle and actual input records.
local state = { modes = { [1] = 7, [2] = 1 }, cp = 437, events = {} }
local native = {
    GetStdHandle = function(n)
        return n == 0xfffffff6 and 1 or 2
    end,
    GetConsoleMode = function(h, out)
        out[0] = state.modes[h]
        return 1
    end,
    SetConsoleMode = function(h, mode)
        state.modes[h] = mode
        return 1
    end,
    GetConsoleOutputCP = function()
        return state.cp
    end,
    SetConsoleOutputCP = function(cp)
        state.cp = cp
        return 1
    end,
    GetTickCount64 = function()
        return 1000
    end,
    WaitForSingleObject = function()
        return 0
    end,
    GetConsoleScreenBufferInfo = function(h, out)
        out[0].window.right = 79
        out[0].window.bottom = 23
        return 1
    end,
    GetNumberOfConsoleInputEvents = function(h, out)
        out[0] = #state.events
        return 1
    end,
    ReadConsoleInputW = function(h, out, n, read)
        local event = table.remove(state.events, 1)
        out[0].type = 1
        out[0].event.key.down = 1
        out[0].event.key.key = event.key or 0
        out[0].event.key.unicode = event.cp or 0
        out[0].event.key.repeats = event.repeats or 1
        read[0] = 1
        return 1
    end,
}
local win = tui.terminal('Windows', native)
win.write = function() end
win:enter()
check(
    bit.band(state.modes[1], 7) == 0 and bit.band(state.modes[2], 4) ~= 0,
    'Windows terminal modes enabled'
)
state.events = {
    { key = 40, repeats = 2 },
    { cp = 32 },
    { cp = 0xd83d },
    { cp = 0xde00 },
    { cp = 13 },
    { cp = 3 },
}
check(
    table.concat(win:keys(0), ',') == 'DOWN,DOWN,SPACE,😀,ENTER,CTRL_C',
    'Windows actual key records normalized'
)
check(select(1, win:size()) == 80, 'Windows viewport dimensions')
win:restore()
check(
    state.modes[1] == 7 and state.modes[2] == 1 and state.cp == 437,
    'Windows modes/codepage restored'
)
print(string.format('PASS: %d duplicate TUI checks', checks))
