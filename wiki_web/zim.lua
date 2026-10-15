#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- zim.lua
-- Zim Desktop Wiki to Leaf Wiki Markdown converter & notebook migration utility
-- High-fidelity conversion of Zim wiki-text, headings, tasks, links, and attachments
--------------------------------------------------------------------------------

local ffi = require('ffi')
local bit = require('bit')

--------------------------------------------------------------------------------
-- OS Platform & Filesystem Declarations
--------------------------------------------------------------------------------
local is_windows = ffi.os == 'Windows'

if is_windows then
    ffi.cdef[[
    typedef struct { unsigned long low, high; } zim_filetime;
    typedef struct { unsigned long attributes; zim_filetime created, accessed, written;
        unsigned long size_high, size_low, reserved0, reserved1;
        uint16_t name[260], alternate[14]; } zim_find_data;
    int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char *, int, uint16_t *, int);
    int __stdcall WideCharToMultiByte(unsigned int, unsigned long, const uint16_t *, int,
        char *, int, const char *, int *);
    void * __stdcall FindFirstFileW(const uint16_t *, zim_find_data *);
    int __stdcall FindNextFileW(void *, zim_find_data *);
    int __stdcall FindClose(void *);
    int __stdcall CreateDirectoryW(const uint16_t *, void *);
    ]]
else
    ffi.cdef[[
    typedef struct zim_dir zim_dir;
    struct zim_dirent {
        unsigned long inode;
        long offset;
        unsigned short length;
        unsigned char kind;
        char name[256];
    };
    zim_dir *opendir(const char *);
    struct zim_dirent *readdir(zim_dir *);
    int closedir(zim_dir *);
    int mkdir(const char *, unsigned int);
    ]]
end

local kernel32 = is_windows and ffi.load('kernel32') or nil
local INVALID_HANDLE = ffi.cast('void *', -1)

local function to_wide(text)
    local count = kernel32.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
    assert(count > 0, 'Path must be valid UTF-8: ' .. tostring(text))
    local buffer = ffi.new('uint16_t[?]', count + 1)
    kernel32.MultiByteToWideChar(65001, 8, text, #text, buffer, count)
    return buffer
end

local function from_wide(buffer, count)
    local bytes = kernel32.WideCharToMultiByte(65001, 0, buffer, count, nil, 0, nil, nil)
    local str = ffi.new('char[?]', bytes)
    kernel32.WideCharToMultiByte(65001, 0, buffer, count, str, bytes, nil, nil)
    return ffi.string(str, bytes)
end

local function normalize_path(path)
    path = path:gsub('\\', '/')
    path = path:gsub('/+', '/')
    return path:gsub('/$', '')
end

local function make_directory(path)
    path = normalize_path(path)
    local parts = {}
    for part in path:gmatch('[^/]+') do
        parts[#parts + 1] = part
    end
    local current = path:sub(1, 1) == '/' and '/' or ''
    if is_windows and path:match('^%a:/') then
        current = parts[1] .. '/'
        table.remove(parts, 1)
    end
    for _, part in ipairs(parts) do
        current = current == '' and part or current .. (current:sub(-1) == '/' and '' or '/') .. part
        if is_windows then
            kernel32.CreateDirectoryW(to_wide(current), nil)
        else
            ffi.C.mkdir(current, 493) -- 0755
        end
    end
end

local function read_file(path)
    local file = io.open(path, 'rb')
    if not file then
        return nil
    end
    local content = file:read('*all')
    file:close()
    return content
end

local function write_file(path, content)
    local dir = path:match('^(.*)/[^/]+$')
    if dir then
        make_directory(dir)
    end
    local file = assert(io.open(path, 'wb'), 'Cannot write file: ' .. path)
    file:write(content)
    file:close()
end

local function list_directory(dir)
    local entries = {}
    dir = normalize_path(dir)
    if is_windows then
        local pattern = dir .. '/*'
        local data = ffi.new('zim_find_data[1]')
        local search = kernel32.FindFirstFileW(to_wide(pattern), data)
        if search ~= INVALID_HANDLE then
            repeat
                local len = 0
                while data[0].name[len] ~= 0 do len = len + 1 end
                local name = from_wide(data[0].name, len)
                if name ~= '.' and name ~= '..' then
                    local is_dir = bit.band(data[0].attributes, 0x10) ~= 0
                    entries[#entries + 1] = { name = name, directory = is_dir }
                end
            until kernel32.FindNextFileW(search, data) == 0
            kernel32.FindClose(search)
        end
    else
        local d = ffi.C.opendir(dir)
        if d ~= nil then
            while true do
                local ent = ffi.C.readdir(d)
                if ent == nil then
                    break
                end
                local name = ffi.string(ent.name)
                if name ~= '.' and name ~= '..' then
                    local is_dir = ent.kind == 4
                    entries[#entries + 1] = { name = name, directory = is_dir }
                end
            end
            ffi.C.closedir(d)
        end
    end
    table.sort(entries, function(a, b) return a.name < b.name end)
    return entries
end

--------------------------------------------------------------------------------
-- Zim Wiki-Text Parser & Markdown Converter
--------------------------------------------------------------------------------
local zim = {}

local function strip_zim_header(text)
    if text:match('^Content%-Type:%s*text/x%-zim%-wiki') then
        local body_start = text:find('\r?\n\r?\n')
        if body_start then
            local header = text:sub(1, body_start - 1)
            local creation = header:match('Creation%-Date:%s*([^\r\n]+)')
            local body = text:sub(body_start):gsub('^\r?\n\r?\n', '')
            return body, creation
        end
    end
    return text, nil
end

local function convert_headings(line)
    local left, title, right = line:match('^(=+)%s*(.-)%s*(=+)%s*$')
    if left and right and #left >= 2 then
        local count = math.min(#left, #right)
        local level = math.max(1, math.min(6, 7 - count))
        return string.rep('#', level) .. ' ' .. title
    end
    return line
end

local function convert_lists_and_tasks(line)
    local indent, rest = line:match('^(%s*)(.*)$')
    if not rest or rest == '' then
        return line
    end
    indent = indent:gsub('\t', '  ')
    local box, task_body = rest:match('^%[([%s%*xX%-%>])%]%s*(.*)$')
    if box then
        local checked = (box == 'x' or box == 'X' or box == '-') and 'x' or ' '
        return indent .. '- [' .. checked .. '] ' .. task_body
    end
    local bullet_body = rest:match('^%*%s+(.*)$')
    if bullet_body then
        return indent .. '- ' .. bullet_body
    end
    return indent .. rest
end

local function convert_links(text)
    return text:gsub('%[%[(.-)%]%]', function(inner)
        local target, label = inner:match('^([^|]+)|(.*)$')
        target = target or inner
        target = target:gsub('^%s+', ''):gsub('%s+$', '')
        if label then
            label = label:gsub('^%s+', ''):gsub('%s+$', '')
        end

        -- External links: http, https, mailto, ftp
        if target:match('^https?://') or target:match('^mailto:') or target:match('^ftp://') then
            if label and label ~= '' then
                return '[' .. label .. '](' .. target .. ')'
            end
            return target
        end

        -- Relative subpage: [[+SubPage]] -> [[./SubPage]]
        if target:sub(1, 1) == '+' then
            target = './' .. target:sub(2)
        end

        -- Absolute root link: [[:RootPage]] -> [[RootPage]]
        if target:sub(1, 1) == ':' then
            target = target:sub(2)
        end

        -- Namespace colons to slashes: [[Projects:Wiki]] -> [[Projects/Wiki]]
        target = target:gsub(':', '/')

        if label and label ~= '' and label ~= target then
            return '[[' .. target .. '|' .. label .. ']]'
        end
        return '[[' .. target .. ']]'
    end)
end

local function convert_images(text, page_folder)
    return text:gsub('{{(.-)}}', function(spec)
        local raw_path, query = spec:match('^([^%?]+)%??(.*)$')
        raw_path = raw_path:gsub('^%./', ''):gsub('^%s+', ''):gsub('%s+$', '')
        local filename = raw_path:match('[^/]+$') or raw_path
        local width = query:match('width=(%d+)')
        local opt = ''
        if width then
            local w = tonumber(width)
            if w and w <= 300 then
                opt = '{width=small}'
            elseif w and w <= 600 then
                opt = '{width=medium}'
            else
                opt = '{width=full}'
            end
        end
        local folder = (page_folder and page_folder ~= '') and (page_folder .. '.attachments/') or ''
        return '![' .. filename .. '](' .. folder .. filename .. ')' .. opt
    end)
end

function zim.convert_text(text, page_id)
    if not text or text == '' then
        return ''
    end
    local body, creation = strip_zim_header(text)
    local page_folder = page_id and page_id:match('[^/]+$') or ''

    -- 1. Protect multiline code blocks and inline code
    local code_blocks = {}
    body = body:gsub('(\r?\n%f[^\r\n%z]%s*\'\'\')([^\r\n]*)(\r?\n.-%f[^\r\n%z]%s*\'\'\')', function(fence, lang, code_body)
        lang = lang:gsub('^%s+', ''):gsub('%s+$', '')
        local code_content = code_body:gsub('^\r?\n', ''):gsub('\'\'\'$', ''):gsub('^\r?\n', '')
        code_blocks[#code_blocks + 1] = '```' .. lang .. '\n' .. code_content .. '\n```'
        return '\n\1ZIM_BLOCK_' .. #code_blocks .. '\1'
    end)

    -- Case where file starts with a code block
    body = body:gsub('^(%f[^\r\n%z]%s*\'\'\')([^\r\n]*)(\r?\n.-%f[^\r\n%z]%s*\'\'\')', function(fence, lang, code_body)
        lang = lang:gsub('^%s+', ''):gsub('%s+$', '')
        local code_content = code_body:gsub('^\r?\n', ''):gsub('\'\'\'$', ''):gsub('^\r?\n', '')
        code_blocks[#code_blocks + 1] = '```' .. lang .. '\n' .. code_content .. '\n```'
        return '\1ZIM_BLOCK_' .. #code_blocks .. '\1'
    end)

    -- Inline code: ''code''
    body = body:gsub("''([^'\r\n]+)''", function(code)
        code_blocks[#code_blocks + 1] = '`' .. code .. '`'
        return '\1ZIM_BLOCK_' .. #code_blocks .. '\1'
    end)

    -- 2. Line-by-line transformations
    local lines = {}
    for line in (body .. '\n'):gmatch('(.-)\r?\n') do
        -- Horizontal rule
        if line:match('^%s*%-%-%-%-+%s*$') then
            line = '---'
        -- Headings
        elseif line:match('^=+%s*.-%s*=+$') then
            line = convert_headings(line)
        -- Lists & Tasks
        else
            line = convert_lists_and_tasks(line)
        end
        lines[#lines + 1] = line
    end
    body = table.concat(lines, '\n')

    -- 3. Inline formatting
    -- Italic: //italic// (avoid matching URLs with ://)
    body = body:gsub('^//([^/\r\n]+)//', '*%1*')
    body = body:gsub('\n//([^/\r\n]+)//', '\n*%1*')
    body = body:gsub('([^:])//([^/\r\n]+)//', '%1*%2*')

    -- Strikethrough: ~~del~~ (same in Markdown)
    -- Underline: __underline__ (keep as __)
    -- Subscript & Superscript
    body = body:gsub('%_%{([^%}%r\n]+)%}', '<sub>%1</sub>')
    body = body:gsub('%^%{([^%}%r\n]+)%}', '<sup>%1</sup>')

    -- 4. Images & Links
    body = convert_images(body, page_folder)
    body = convert_links(body)

    -- 5. Restore code blocks
    body = body:gsub('\1ZIM_BLOCK_(%d+)\1', function(id)
        return code_blocks[tonumber(id)] or ''
    end)

    -- Strip excessive trailing blank lines, ensure single final newline
    body = body:gsub('%s+$', '') .. '\n'
    return body
end

--------------------------------------------------------------------------------
-- Zim Directory Scanner & Notebook Migration
--------------------------------------------------------------------------------
local function is_image_file(name)
    local ext = name:match('%.([%a%d]+)$')
    if not ext then
        return false
    end
    ext = ext:lower()
    return ext == 'png' or ext == 'jpg' or ext == 'jpeg' or ext == 'gif' or ext == 'webp'
end

function zim.scan_zim_tree(source_dir)
    source_dir = normalize_path(source_dir)
    local pages = {}
    local attachments = {}
    local metadata = {}

    local config_text = read_file(source_dir .. '/notebook.zim')
    if config_text then
        metadata.name = config_text:match('name=([^\r\n]+)')
        metadata.home = config_text:match('home=([^\r\n]+)')
    end

    local function scan_dir(current_dir, relative_prefix)
        local entries = list_directory(current_dir)
        for _, entry in ipairs(entries) do
            local rel_path = (relative_prefix == '' and entry.name or relative_prefix .. '/' .. entry.name)
            if entry.directory then
                scan_dir(current_dir .. '/' .. entry.name, rel_path)
            else
                local name = entry.name
                if name:match('%.txt$') then
                    local page_id = rel_path:sub(1, -5)
                    pages[#pages + 1] = {
                        id = page_id,
                        zim_path = current_dir .. '/' .. name,
                        rel_path = rel_path,
                    }
                elseif is_image_file(name) then
                    attachments[#attachments + 1] = {
                        name = name,
                        source_path = current_dir .. '/' .. name,
                        rel_path = rel_path,
                    }
                end
            end
        end
    end

    scan_dir(source_dir, '')
    table.sort(pages, function(a, b) return a.id < b.id end)
    return {
        metadata = metadata,
        pages = pages,
        attachments = attachments,
    }
end

function zim.import_notebook(source_dir, target_dir, options)
    options = options or {}
    source_dir = normalize_path(source_dir)
    target_dir = normalize_path(target_dir)

    local progress = options.progress or function() end
    progress('Scanning Zim notebook: ' .. source_dir)

    local tree = zim.scan_zim_tree(source_dir)
    progress(string.format('Found %d pages and %d media attachments', #tree.pages, #tree.attachments))

    make_directory(target_dir)

    local page_count = 0
    local image_count = 0
    local errors = {}

    -- 1. Convert and write pages
    for _, page in ipairs(tree.pages) do
        local raw = read_file(page.zim_path)
        if raw then
            local markdown = zim.convert_text(raw, page.id)
            local target_path = target_dir .. '/' .. page.id .. '.md'
            local ok, err = pcall(write_file, target_path, markdown)
            if ok then
                page_count = page_count + 1
            else
                errors[#errors + 1] = 'Failed to write ' .. page.id .. ': ' .. tostring(err)
            end
        else
            errors[#errors + 1] = 'Failed to read ' .. page.zim_path
        end
    end

    -- 2. Reorganize and copy image attachments into Leaf Wiki's *.attachments/ folders
    -- In Zim, page attachments for Page.txt are placed in Page/ or in the same directory.
    for _, att in ipairs(tree.attachments) do
        -- Find the best matching page owner
        local owner_id = nil
        local parent_dir = att.rel_path:match('^(.*)/[^/]+$') or ''

        for _, page in ipairs(tree.pages) do
            if page.id == parent_dir then
                owner_id = page.id
                break
            end
        end

        if not owner_id and parent_dir ~= '' then
            for _, page in ipairs(tree.pages) do
                if page.id:sub(1, #parent_dir) == parent_dir then
                    owner_id = page.id
                    break
                end
            end
        end

        if not owner_id and #tree.pages > 0 then
            owner_id = tree.pages[1].id
        end

        if owner_id then
            local target_folder = target_dir .. '/' .. owner_id .. '.attachments'
            make_directory(target_folder)
            local target_file = target_folder .. '/' .. att.name
            local bytes = read_file(att.source_path)
            if bytes then
                local ok = pcall(write_file, target_file, bytes)
                if ok then
                    image_count = image_count + 1
                else
                    errors[#errors + 1] = 'Failed to copy attachment: ' .. att.name
                end
            end
        end
    end

    progress(string.format('Migration complete: %d pages converted, %d images copied, %d errors',
        page_count, image_count, #errors))

    return {
        pages_converted = page_count,
        images_copied = image_count,
        errors = errors,
        metadata = tree.metadata,
    }
end

--------------------------------------------------------------------------------
-- CLI Runner
--------------------------------------------------------------------------------
function zim.cli(args)
    local source = args[1]
    local destination = args[2]

    if not source or source == '-h' or source == '--help' then
        print('Usage: luajit wiki_web/zim.lua <source_zim_folder> [destination_leaf_folder]')
        print('')
        print('Converts a Zim Desktop Wiki notebook to a Leaf Wiki Markdown notebook.')
        print('Example:')
        print('  luajit wiki_web/zim.lua C:/Notes/ZimNotebook C:/Notes/LeafWiki')
        return
    end

    destination = destination or (source:gsub('/+$', '') .. '_leaf')

    print('=== Leaf Wiki: Zim Notebook Importer ===')
    print('Source:      ' .. source)
    print('Destination: ' .. destination)
    print('')

    local result = zim.import_notebook(source, destination, {
        progress = function(msg)
            print('  -> ' .. msg)
        end,
    })

    print('')
    if #result.errors > 0 then
        print('Warnings / Errors encountered:')
        for _, err in ipairs(result.errors) do
            print('  [!] ' .. err)
        end
        print('')
    end

    print(string.format('Finished! Converted %d pages and %d image attachments.',
        result.pages_converted, result.images_copied))
    print('You can open this notebook in Leaf Wiki:')
    print('  luajit wiki_web.lua --data-dir ' .. destination)
end

if not pcall(debug.getlocal, 4, 1) and arg and arg[0] and arg[0]:match('zim%.lua$') then
    zim.cli(arg)
end

return zim
