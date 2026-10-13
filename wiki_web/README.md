# Leaf Wiki

A local personal wiki: LuaJIT serves a browser editor, Markdown files hold your
pages, and a local SQLite index supplies search and backlinks. No npm install or
Python backend is needed. Supports Linux x86-64 and Windows 10/11 with LuaJIT.

## Run

On Linux, install LuaJIT and the SQLite and OpenSSL shared libraries:

```sh
sudo apt install luajit libsqlite3-0 libssl3
luajit wiki_web.lua
```

On Windows, install LuaJIT and put a matching-architecture `sqlite3.dll` beside
`luajit.exe` or on `PATH`. The SQLite DLL is available from
[SQLite's Windows downloads](https://www.sqlite.org/download.html).
Windows uses built-in Winsock and BCrypt; libcurl and OpenSSL are not required.
Run from PowerShell:

```powershell
luajit .\wiki_web.lua --data-dir C:\Notes\LeafWiki --save-config
```

List SQLite DLLs, choose one, and save its verified path without starting the server:

```powershell
luajit .\wiki_web.lua --sqlite-select
```

Use `--config FILE` to select a configuration file. Existing settings are preserved;
missing configuration directories are created. `--sqlite-list` lists candidates without
loading them. `--sqlite-dll PATH --save-config` pins a known DLL during normal startup.
Selection checks architecture, required SQLite APIs, and UPSERT support. FTS5 is not required.
The override order is `--sqlite-dll`, `LEAF_WIKI_SQLITE3`, then saved `sqlite_dll`.
Invalid overrides fail with an error rather than silently selecting another DLL.
`--sqlite-select` ignores an old environment or saved pin so you can replace it.

Notebook names and paths support UTF-8, including Chinese characters. Examples
use folders without spaces; paths containing spaces also work when quoted.
Windows path options accept either separator, relative paths, `.` and `..`,
`~`, and environment variables such as `%USERPROFILE%`. Paths are resolved to
absolute `C:/...` form for diagnostics and saved JSON; UNC prefixes are preserved.
Normalization does not create a file or folder. Missing directories are created
only by operations that require them, such as saving config or opening a notebook.

Open **http://127.0.0.1:8020** on the host computer. By default the server listens
only on `127.0.0.1`, so it is accessible from this computer. The default notebook
is `~/LeafWiki`. To enable LAN access explicitly:

```powershell
luajit .\wiki_web.lua --host 0.0.0.0
```

Then open `http://<host-LAN-IP>:8020` or `http://<host-name>:8020` from another
device. LAN mode listens on both IPv4 and IPv6, so names such as `nano.local`
work when resolved to either address family. IPv6 support must be enabled on the
server; startup reports an error if a dual-stack listener cannot be created.
Allow inbound TCP port `8020` through the host firewall. Leaf Wiki has
no login, so only enable LAN access on a trusted network. `--host` applies to the
current launch and is not saved by `--save-config`. Ctrl-C closes the server and
index on both platforms; SIGTERM also does so on Linux. Windows process termination
(for example, Node's `child.kill()`) is a forced exit; transaction recovery runs
on the next launch. An absolute launcher path works from any working directory.

Choose another notebook folder:

```sh
luajit wiki_web.lua --data-dir /home/zliu/LeafWiki
```

Save the selected path for subsequent launches:

```sh
luajit wiki_web.lua --data-dir /home/zliu/LeafWiki --save-config
luajit wiki_web.lua
```

Configuration lives in `$XDG_CONFIG_HOME/leaf-wiki/config.json`, or
`~/.config/leaf-wiki/config.json` when that environment variable is unset:

```json
{
  "data_dir": "/home/zliu/LeafWiki"
}
```

On Windows the default notebook is `%USERPROFILE%\LeafWiki`, configuration is
`%APPDATA%\leaf-wiki\config.json`, and the rebuildable index cache is under
`%LOCALAPPDATA%\leaf-wiki`. Explicit command options override these defaults.

Selection order is `--data-dir`, `LEAF_WIKI_DATA_DIR`, saved configuration, then
the default. `--config FILE`, `--cache-dir PATH`, and `--port NUMBER` override
their respective defaults. Use `--help` for usage; port `0` picks a free port.

Pages and pasted images are saved in the selected folder. The rebuildable index
stays in `$XDG_CACHE_HOME/leaf-wiki`, or `~/.cache/leaf-wiki`, under a separate
directory for each notebook. A cache inside the notebook is rejected.

Google Drive needs a folder available through a sync client or filesystem mount.
Leaf Wiki does not authenticate with Google or call its API. Prefer a synced
local folder; a mount must support normal file operations, atomic renames, and
file flushing. One device should edit a notebook at a time: revision checks
detect visible external edits, but cannot coordinate simultaneous cloud writes
or guarantee that a sync client has uploaded them. Back up the entire notebook
folder, including attachments and `.leaf` if you want to retain trashed pages.

## Startup diagnostics

Both `luajit wiki_web.lua` and `luajit app.lua` from the `wiki_web` folder print
flushed startup phases: module loading, configuration, notebook locking, cache
setup, indexing, and HTTP startup. Larger notebooks also show indexing progress.
If startup fails, the app reports **Leaf Wiki failed during: ...**, prints the
underlying error and traceback, and exits with status 1. The normal URL appears
when the server is ready. `--help` keeps its concise usage output.

Run from PowerShell to keep errors visible. Capture both output streams with:

```powershell
luajit .\wiki_web.lua 2>&1 | Tee-Object wiki-startup.log
```

If the process still exits abruptly without an error report, the last phase
identifies where it stopped. Immediately inspect `$LASTEXITCODE`; native DLL
crashes and forced termination cannot be caught by Lua's error handler. Verify
that LuaJIT and `sqlite3.dll` have matching architectures.

A missing default configuration is a normal first-run condition: startup explicitly
says it is using defaults. An absent `--config` file produces a warning, unless
`--save-config` is creating it. Configuration folders are created only when saving.
After `--save-config`, startup reads the file back, verifies its saved settings,
and prints **Configuration saved and verified:** followed by its absolute path.
Write or verification failures stop startup and never print a success message.
The rebuildable SQLite search index is created automatically; startup distinguishes
**Creating SQLite search index** from **Opening SQLite index**. An unreadable or
corrupt search index is a fatal startup error. The optional dictionary is checked
read-only at startup: missing or incompatible databases produce a warning without
creating an empty file. Notebook editing remains available. Use `--dict-db none`
to disable dictionary lookup explicitly.

Missing or unreadable resources include setup/recovery help. Config diagnostics
show the `--save-config` command (which creates missing parent directories) and
a minimal JSON example. SQLite search-index failures show how to select a fresh
writable cache folder, which creates and rebuilds the index automatically.
Dictionary warnings show import instructions for Linux/WSL and how to configure
an imported file or disable lookup. Existing files are never automatically deleted
or replaced as part of recovery advice.

## Writing and navigation

- **+ Page** creates a page. Use `/` or `:` between namespace components, such
  as `Projects/Wiki/Design`. Pages are ordinary UTF-8 `.md` files.
- The **Journal** calendar opens or creates a daily page for the selected date.
  Entries use `Journal/YYYY/MM/YYYY-MM-DD.md` and remain regular searchable,
  linkable Markdown pages. New entries have a date-and-weekday heading, such as
  `# 2026-10-11 Sunday`. Opening an older default journal heading adds the
  weekday while preserving its entry text. **Today** jumps to the current date.
- Choose **Edit**, **Split**, or **Preview**. Narrow screens default to Edit;
  the notebook tree opens with the menu button.
- Supported Markdown includes headings, paragraphs, lists, task checkboxes,
  emphasis, inline/fenced code, blockquotes, links, and local images. Task
  checkboxes are display-only; change `[ ]` to `[x]` in the editor. Raw HTML is
  shown as text. This is a deliberately limited renderer, not full CommonMark.
- Use `[[Home]]`, `[[Projects:Wiki:Tasks|Tasks]]`, or
  `[[Projects/Wiki/Tasks#next-steps]]` for notebook links. Unprefixed links address
  the notebook root. `[[./Tasks]]` and `[[../Other]]` resolve relative to the
  current page's containing folder. Missing targets offer page creation.
- **Linked from** lists backlinks. Links inside code are excluded.
- **Outline** opens the document heading outline to navigate long notes.
  Clicking an outline item jumps directly to that section in the editor and preview.
  The outline updates live as headings are typed.
- Search matches page paths, titles, and content. Search supports filters such
  as `tag:work` (or `#work`) and `path:Projects` (or `path:"My Projects"`),
  alongside free-text terms. Search results display contextual snippets centered
  around matching terms with highlighted search keywords in titles, paths, and snippets.
  **Ctrl K** (or Cmd K) focuses search; **Ctrl S** (or Cmd S) saves immediately.

## Tags

Add hashtags such as `#work`, `#team-one`, or `#学习` to your page's Markdown.
Choose a tag from **Filter by tag** in the sidebar to group pages across folders.
Tag filters also apply to search results. Editing, renaming, trashing, and restoring
pages updates their tags automatically. Tags inside inline or fenced code are
ignored, as are heading markers and URL fragments. ASCII tags are case-insensitive;
Unicode spelling is preserved. Tags can contain letters, digits, underscores,
and hyphens, up to 64 UTF-8 bytes. They remain ordinary Markdown in your backups.

## Page templates

Click **+ Page**, enter a page name, and choose a template. Built-in starters are
**Blank**, **Journal**, **Study notes**, and **Meeting notes**. The dialog previews
the Markdown before creation. Templates apply only to new pages; an existing
page is never overwritten, and renaming does not apply a template.

For a custom template, create an ordinary page such as `Templates/Study`, choose
Blank, then edit and save its Markdown. It appears as **Custom · Study** in the
template selector the next time you create a page. Nested names such as
`Templates/Work/Meeting` are supported. Custom templates remain searchable,
editable Markdown pages and are included in normal notebook backups.

Supported placeholders:

| Placeholder | Value |
|---|---|
| `{{title}}` | New page's final name component |
| `{{path}}` | Full new page path |
| `{{date}}` | Local date as `YYYY-MM-DD` |
| `{{weekday}}` | English weekday name |

For a valid `Journal/YYYY/MM/YYYY-MM-DD` page, date placeholders use that page's
date. Other pages use today's local date. Unknown placeholders remain literal.
For example, save this in `Templates/Study`:

```markdown
# {{title}}
Date: {{date}} · {{weekday}}

## Key ideas

## Questions

## Summary
```

Custom templates are loaded when selected. If a template cannot be read, choose
another template or correct its page before creating the new note. The journal
calendar continues to create its usual daily heading; select the Journal starter
in **+ Page** when you want its additional sections. Template links and image
references are copied literally, so use notebook wiki links for shared references
and add owning-page images after creation.

## Quick page switcher

Press **Ctrl P** (Cmd P on macOS), or click **Open page**, to find a page by name
or path. Type to filter immediately, use **↑ / ↓** to select, and press **Enter**
to open it. **Esc** closes the switcher and returns focus to where you were.
Results prioritize exact names and prefixes; spaces match multiple path fragments,
and `:` can stand in for `/`. Unicode names are supported. Up to 50 results are
shown; narrow the query to reach a page in a larger notebook.

Filtering uses the loaded notebook list without network requests. Opening a page
saves your current draft first; a save failure or revision conflict keeps the
draft and switcher open. A removed or unreadable page reports an error. The
switcher is unavailable while another modal dialog is open.

## Quick capture

Click **Capture** or press **Ctrl Shift J** (Cmd Shift J on macOS). Enter a thought,
choose **Note** or **Task**, then click **Add to journal** or press **Ctrl Enter**
(Cmd Enter). Capture appends to `Journal/YYYY/MM/YYYY-MM-DD.md` and creates its
dated heading when the page is missing. Your current page stays open. Tasks use
`- [ ]` Markdown and appear in the task dashboard; additional lines become indented
continuations of the same task. Notes keep their Markdown formatting.

The destination date uses your browser's local date when you open Capture and is
shown in the dialog. It stays fixed while the dialog is open, including across
midnight. Reopen Capture to use a new date. Input is limited to 4,000 characters
in the browser and 16,000 UTF-8 bytes on the server.

An unrelated editor draft stays intact. If today's journal is already open,
Capture saves that draft before appending and updates the editor after success.
Conflicting journal edits are rejected without overwriting either version.
Resolve an open journal's editor conflict before retrying; captures to another
page read its latest revision on each attempt. Appending saves page history and
reads the file back before reporting success.

Failures retain capture text, and **Cancel** or **Esc** closes the dialog while
keeping it for the next opening in this tab. After success the input clears and
the dialog confirms the saved date. Capture text is kept in memory only; the
browser warns before leaving with pending text, but a reload or closed tab can
lose it. If a connection fails during submission, inspect the journal before
retrying because the save may have completed. Capture never retries automatically.

## Task dashboard

Click **Tasks** to collect Markdown checklist items from all active pages. Search
task text or page paths, and filter by completion, folder (including subfolders),
page tag, or due date. The default view shows open tasks. Results sort by due date,
then page and line; **Show more** adds another 100 results. Filters remain selected
when you refresh or reopen the dashboard.

```markdown
# Home Lab #work
- [ ] Review network setup due:2026-10-15
- [x] Enable IPv6
```

Use `due:YYYY-MM-DD` as a separate word in a task. Invalid dates are treated as
having no due date. Today and overdue use the browser's local date. Tag filtering
uses all tags on the source page, matching the notebook's existing tag filter.
Tasks support `-`, `+`, `*`, and numbered list markers, with zero to three leading
spaces. Fenced code and lines indented by four spaces or a tab are excluded;
deeply indented task lists are therefore excluded too. Tasks remain plain Markdown.

Check or uncheck a task to update only its checkbox in the source page. The edit
uses revision checks and saves page history. Duplicate labels are distinguished
by their source lines. If a page changed, the dashboard reports a conflict and
asks you to refresh; it never retries with a newer revision automatically.
Opening Tasks first saves the current draft, and an unresolved editor conflict
blocks task changes. Click the source page and line to select the task in the
editor. A changed page or recovered draft must be inspected before jumping to
an old line number. Use **Refresh** to discover external edits while Tasks is open.

## Dictionary lookup

Select a word in the Markdown editor or rendered preview, then click **Look up**.
The dictionary panel shows definitions, examples, synonyms, and antonyms alongside
your page. You can also type a word or short phrase and press **Find**. On narrow
screens the panel sits above the editor. Lookup never changes your note.

Lookup reads an existing local dictionary in the `ffi_dict` SQLite format.
By default it uses `.dict.db` next to `wiki_web.lua`. Configure another file:

```powershell
luajit .\wiki_web.lua --dict-db C:\Notes\dict.db --save-config
```

The path is saved as `dict_db` in the same configuration file as `data_dir`.
Selection order is `--dict-db`, saved configuration, then the repository's
`.dict.db`. Use `--dict-db none` to disable lookup. Definitions are read-only;
the dictionary and vocabulary deck are never changed. No network request or
additional runtime library is needed. If the database is missing or incompatible,
the panel explains how to configure it and notebook editing remains available.

Reuse a dictionary already imported with `ffi_dict` or `download_dict`. To obtain
the Wordset dictionary on Linux (or WSL), run from this repository:

```sh
luajit download_dict.lua --db .dict.db
```

Downloading requires Git and internet access. After import, lookup works offline
on both platforms; Windows can read the same database file. Dictionary download
and import are separate from launching Leaf Wiki.

## Autosave and conflicting edits

Typing schedules a save after a short pause. The status distinguishes unsaved
edits, saving, saved, failures, and conflicts. Page navigation waits for a
successful save. Edits typed during an in-flight save remain unsaved until their
own save succeeds.

The editor keeps a recovery draft in browser storage when available. On a save
failure, the editor retains your text. If the file changed externally, copy the
draft before using **Load saved file**; the server rejects stale revisions.
External changes are scanned on notebook requests and every five seconds while
the editor is idle. Reloading the file requires confirmation.

Do not depend on browser drafts as a backup: they are specific to this browser
origin, including its port, and may be disabled or cleared. Revision checks cover
cooperating browser clients and already-visible edits; an external writer that
changes a file during the final atomic-save window can still race the save.

## Page revision history

Open **History** on a page to browse earlier Markdown versions. Select a version
to preview its text, then choose **Restore this version** and confirm. Unsaved
edits must save successfully before opening history. Restoring archives the
current saved text first; an external edit causes a conflict instead of being
overwritten. Versions matching the current text cannot be restored again.

Before a changed save, rename, backlink rewrite, or trash operation replaces a
page, Leaf Wiki writes its current Markdown into `.leaf/history`. History follows
renames and survives trash/restore, restarts, and search-cache rebuilds. Restoring
an older version after a rename adjusts relative wiki links and owning-page image
references to the current page location.

Snapshots contain Markdown only; image files are not versioned. Versions saved
before this feature was installed cannot be recovered, and edits made entirely
outside Leaf Wiki between its saves are not captured. History is associated with
page paths: reusing an old path retains that path's earlier history. Identical
content shares a snapshot, and history is never automatically pruned, so disk
usage grows with distinct versions. Include `.leaf/history` in notebook backups.
If a snapshot or history manifest is damaged, preserve it for manual recovery;
Leaf Wiki rejects damaged snapshots and blocks changes when history cannot be
written safely. A page's history manifest is limited to 32 MiB.

## Images

Paste a copied image into the editor or drag an image file onto it. The app saves
the image and inserts a Markdown link:

```markdown
![Image](Design.attachments/1c4a…7f.png)
```

Supported formats are PNG, JPEG, GIF, and WebP, up to 5 MiB each. The server
checks the file signature and uses a content-derived filename; repeated images
reuse the same file. SVG and arbitrary uploaded files are excluded. Image links
currently support the owning page's attachment directory only. Rename updates
that directory and its references. Trash and restore include page images.

Removing an image link does not delete its file; unused attachments remain in
the notebook. Images already linked before an interrupted upload remain stored
even if the Markdown save fails, so you can recover them from the folder.

## Rename and trash

**Rename** moves a single page, updates incoming wiki links, and preserves its
outgoing relative links and images. Child pages remain at their existing paths;
subtree moves are a later feature. A destination page or attachment-directory
collision is rejected.

**Trash page** removes one page and its images from the active notebook. Child
pages remain. Open **Trash** to restore it. Restoration rejects occupied page
paths or attachment directories.

Multi-file maintenance uses a recovery journal in `.leaf/transaction.json`.
An interrupted operation is rolled back when the notebook next starts. Recovery
stops if a participating Markdown file has been edited externally; preserve the
files and journal for manual reconciliation. The notebook uses a local advisory
lock to prevent two Leaf Wiki servers from opening the same folder on one device.

## Limits and compatibility

Pages are limited to 1 MiB, names to 240 UTF-8 bytes, nesting to 16 components,
and notebook indexing to 2,000 pages. Names cannot contain control characters,
backslashes, wiki syntax delimiters, hidden components, or `.attachments`
components. Notebook symlinks are not followed. Invalid or oversized existing
pages produce an error so they can be corrected externally. On Windows, junctions
and other reparse points are also excluded. Windows device names, reserved
filename characters, and names ending in a dot are rejected; the spelling and
case of existing filenames must match exactly to prevent duplicate index entries.

The app does not read Zim's wiki-text format. Existing `.md` files can be placed
in the notebook and indexed automatically. Zim import and weekly/monthly journal
views remain future work.

## HTML export

Click **Export** and choose **Current page** or **Whole notebook**. Leaf Wiki
saves your draft first, then downloads a standalone HTML file with local images
embedded. Open it in a browser without running Leaf Wiki. Notebook exports
include all active pages, regardless of the current search or tag filter; trash
and revision history are excluded. Links between included pages work offline.
Links to pages outside the export are shown without a clickable target. External
web links still require network access. The exported file contains no scripts.

Export uses the same safe Markdown subset as the preview. Raw HTML remains text.
The complete HTML file is limited to 64 MiB; export individual pages if your
notebook exceeds that limit. A missing image, unreadable page, or page revision
that changes during retrieval stops the export without downloading a partial
file. **Cancel** aborts the operation. Images and page contents are included in
the download, so review it before sharing it. Browser print can produce a PDF.

## Verify

From the repository root:

```sh
luajit wiki_web/tests/test_notebook.lua
python3 wiki_web/tests/test_linux_http.py
node --test wiki_web/tests/test_http.js wiki_web/tests/test_ui.js
node --check wiki_web/static/app.js
node --check wiki_web/static/markdown.js
node --check wiki_web/static/export.js
node --test dictionary_web/tests/test_http.js dictionary_web/tests/test_ui.js dictionary_web/tests/test_theme.js
```

On Windows, run the Wiki Web Node commands above. The HTTP suite also runs all notebook
unit tests and cleans their temporary folders; the standalone Lua unit-test
command and the optional Python signal regression are for Linux. The shared
dictionary HTTP regression suite also requires Linux. Windows tests additionally
cover Unicode command-line and configuration paths, junction confinement,
filename aliases, notebook locking,
and console Ctrl-C cleanup.

For optional real-browser selection and desktop/mobile layout checks, install
Playwright as test tooling and run `node --test wiki_web/tests/test_browser.js`.
The suite skips when Playwright is unavailable. `LEAF_WIKI_PLAYWRIGHT` can point
to an external Playwright installation; `PLAYWRIGHT_EXECUTABLE_PATH` selects a
browser binary (Windows defaults to installed Microsoft Edge).

Tests use temporary notebooks and caches. They exercise real HTTP configuration,
large pages, revision conflicts, search, links, image serving, restart persistence,
path confinement, maintenance rollback, clipboard input, save races, and LuaJIT
bytecode scoping. Verify actual browser clipboard paste and drag-and-drop on your
device, as clipboard image availability depends on the browser and source app.
