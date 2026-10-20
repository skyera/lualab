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
  linkable Markdown pages. If a `Templates/Journal` page exists, new daily pages
  automatically expand its `{{title}}`, `{{path}}`, `{{date}}`, and `{{weekday}}`
  placeholders; otherwise they start with `# YYYY-MM-DD Weekday` (such as
  `# 2026-10-11 Sunday`). Opening an older default journal heading adds the
  weekday while preserving its entry text. Calendar days are shaded by entry
  length (`heat-1` to `heat-4`), and the sidebar displays your current streak,
  best streak, and days written in the viewed month. **Today** jumps to the current date.
- Choose **Edit**, **Split**, or **Preview**. In **Split** mode, scrolling either
  the Markdown editor or the rendered preview keeps both panes proportionally aligned.
  Narrow screens default to Edit; the notebook tree opens with the menu button.
- Supported Markdown includes headings, paragraphs, lists, task checkboxes,
  emphasis, strikethrough (`~~text~~`), inline/fenced code with one-click copy buttons,
  blockquotes, GitHub-style alert callouts (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`,
  `> [!WARNING]`, `> [!CAUTION]`), tables, links, and local images. Task checkboxes in
  the rendered preview can be clicked directly to toggle completion; checking or unchecking
  updates its Markdown in the editor and schedules an autosave. Raw HTML is shown as text.
  This is a deliberately limited renderer, not full CommonMark.
- Use `[[Home]]`, `[[Projects:Wiki:Tasks|Tasks]]`, or
  `[[Projects/Wiki/Tasks#next-steps]]` for notebook links. Unprefixed links address
  the notebook root. `[[./Tasks]]` and `[[../Other]]` resolve relative to the
  current page's containing folder. Missing targets offer page creation.
- **Linked from** lists backlinks. Links inside code are excluded.
- **Outline** opens the document heading outline to navigate long notes.
  Clicking an outline item jumps directly to that section in the editor and preview.
  The outline updates live as headings are typed.
- **Verse** opens a dialog to fetch a random Bible verse from public-domain translations
  (World English Bible, King James Version, Bible in Basic English, Open English Bible)
  and insert it directly into the editor as a formatted blockquote quotation.
- Search matches page paths, titles, and content. Search supports filters such
  as `tag:work` (or `#work`) and `path:Projects` (or `path:"My Projects"`),
  alongside free-text terms. Search results display contextual snippets centered
  around matching terms with highlighted search keywords in titles, paths, and snippets.
  **Ctrl K** (or Cmd K) focuses search; **Ctrl S** (or Cmd S) saves immediately.
  Press **?** (or click **?** in the header) to open the keyboard shortcuts reference.
- Typing `[[` in the editor opens page-name suggestions ranked by exact name, prefix, then
  substring match (`:` works as `/`). Use **Up/Down** to choose, **Enter** or **Tab** (or a click)
  to insert `Page]]`, and **Esc** to dismiss. Suggestions use the loaded notebook list, so no
  network requests are made.
- **Graph** opens an interactive 2D node-link graph of note connections. Drag nodes,
  scroll to zoom, drag the background to pan, hover to highlight connected neighbors,
  filter by title/tag in real time, and click any node to navigate directly to it.

## Notebook dashboard

Click **Dashboard** in the header for a notebook-wide overview. Opening it first
saves the current draft; a failed save or conflict keeps the draft in the editor.
**Back to editor** or **Esc** closes the dashboard without changing the current
page, cursor, or scroll position.

The summary counts active pages, physical supported image files belonging to
active pages, and all open tasks. Missing referenced images are excluded from the
image count. Pinned and recent pages use the same notebook-specific preferences
as the sidebar. Lists show up to 10 entries. **Upcoming tasks** shows dated open
tasks in due-date order, including overdue tasks first; completed and undated
tasks are omitted from that list. Popular tags are ranked by the number of pages
using each tag, with alphabetical ties.

Click a saved page shortcut to open it. Clicking a task opens its page and selects
the source line only when its saved revision still matches and no recovered draft
changes the text. If it changed, the dashboard reports the conflict; return to
the editor to inspect it or refresh the task list. Clicking a popular tag clears
the search and filters the sidebar while keeping the current editor page.

Quick actions open **Today’s journal**, **Quick capture**, **+ Page**, **All
tasks**, or **Graph view** using their existing safeguards. **Refresh** reloads the overview. Page,
image, and task requests fail independently: an unavailable count is shown as
`—` with a visible error and retry guidance, while successfully loaded sections
remain usable. Closing or refreshing ignores late responses from previous loads.
The dashboard itself is read-only; quick actions can create or edit pages through
the normal flows. Header controls wrap to remain accessible on smaller screens.

## Interactive notebook graph view

Click **Graph** in the header or **Graph view** in the dashboard to open the
interactive 2D graph view. The graph visualizes notes as nodes and wiki links as
edges, powered by a physics-based force simulation:

- **Node sizing & connections**: Node diameter scales with connection degree
  (incoming and outgoing links). Connected notes naturally cluster together.
- **Navigation**: Click any node to close the graph and jump directly to that note.
- **Pan & Zoom**: Drag the canvas background to pan across large notebooks; use
  the mouse wheel to zoom in and out smoothly. Double-click or click **Reset view**
  to re-center.
- **Neighbor highlighting**: Hover over any note to highlight its immediate 1-hop
  connections and labels while softly dimming unrelated notes. Tooltips display note
  title, link counts, and tags.
- **Real-time filtering**: Enter text or `#tags` into the graph search box to
  instantly highlight matching notes and dim non-matching notes.
- **Theme integration**: Graph nodes, links, and background automatically adapt to
  the active color theme (Paper, Midnight, Sepia, Ocean).

## Color themes

Use the header's **Theme** selector for Paper (the default), Midnight (Dark Mode),
Sepia, Ocean, or System. System follows OS dark/light mode automatically via
`prefers-color-scheme`. Themes are applied immediately before page rendering to
avoid screen flashes, and choices persist across reloads in `localStorage`. Theme
selection remains fully functional in memory even when browser storage is blocked.
All palettes maintain a minimum 4.5:1 WCAG AA contrast ratio for high readability.

## Markdown editing toolbar

Use the buttons above the Markdown editor to format selected text or insert a
starter at the cursor:

- **Bold**, **Italic**, and **Strike** wrap the selection in `**`, `*`, or `~~` markers.
- **Heading** makes selected lines level-one headings. **Task** turns selected
  lines into task checkboxes, preserving already completed tasks and blank lines.
- **Link** wraps a valid selected wiki page name in `[[...]]`, or inserts `[[Page]]`.
- **Code** wraps short selections in backticks. Multiline selections or selections
  beginning/ending with backticks use fenced blocks with a safe delimiter length.
  Rendered code blocks include a one-click **Copy** button.
- **Callout** turns selected lines into a GitHub-style `> [!NOTE]` callout card
  with icon, border accent, and theme palette colors.
- **Table** inserts a two-column starter with two data rows. Existing selected
  text is preserved after the inserted template. The first column name is selected
  for editing.

Formatting returns focus to the editor and uses normal draft recovery, preview,
statistics, and autosave. When no text is selected, placeholder text is selected
for replacement. Browser insertion preserves native undo when available; the
status reports the fallback when it is unavailable. **Undo format** reverts the
latest toolbar action and restores its original selection. Typing, page reloads,
and other editor changes invalidate that button so it cannot overwrite newer text.
Loading or read-only editors reject formatting with a visible diagnostic.

## Page statistics

Click **Statistics** in a page's toolbar to open a panel that updates as you type.
**Close** hides it and returns focus to its toolbar button. Counts use the current
editor text, including recovered and unsaved drafts; saving does not change them.
The footer uses the same word count.

- **Words** counts Unicode letter/number groups, including combining marks and
  internal apostrophes. Punctuation alone is not a word. Code and Markdown source
  labels, paths, and URLs contribute to this source count. Unspaced Chinese text
  counts as one group rather than receiving linguistic word segmentation.
- **Characters** counts Unicode code points, including spaces, newlines, and
  Markdown syntax. An emoji outside the basic multilingual plane counts once;
  combining marks and multi-code-point emoji sequences count individually.
- **Reading time** estimates 200 source words per minute, rounded up. Empty text
  has a zero-minute estimate.
- **Headings** counts rendered heading elements, excluding code examples.
- **Outgoing wiki pages** counts distinct valid wiki targets, including missing
  pages, excluding the current page. Repeated links and different heading anchors
  on the same target count once. External web links are excluded.
- **Backlinks** counts distinct source pages in the current page's last-loaded
  saved backlink data. Reopen the page to refresh external backlink changes.
- **Images** counts rendered image occurrences, including repeated uses of the
  same attachment. Code examples and unsupported image paths are excluded.

Statistics are computed locally and do not write files or make extra requests.

## Saved searches

Enter a query, click **Save search** beside the search field, and give it a name.
Saved searches appear in the sidebar with their exact queries. Click a name to
restore and run its query immediately. This clears the separate sidebar tag
filter; include `tag:work` in the query when a tag restriction should be saved.
Searches do not navigate away from the editor or modify its draft.

Use **Rename** to change a saved search's name without changing its query, or
**Delete** to remove it after confirmation. Saving an identical query opens its
rename dialog rather than creating a duplicate. Names are unique regardless of
case. Up to 100 searches can be stored, with names of 1–120 characters and
queries of 1–4,096 characters. Query spacing, quotes, and Unicode are preserved.

Searches use browser storage keyed by notebook path, separately from pinned and
recent pages. They survive reloads on the same browser origin, but are not synced
or included in notebook backups. Saves are read back and verified. Storage
errors remain visible in the sidebar and naming dialog; failed writes keep
changes in this session and allow retry without losing the name or query.
Malformed stored data is preserved; repair or remove the storage entry named in
the diagnostic and reload. When storage cannot be loaded, searches still work
for the session only.

## Weekly and monthly journal overviews

Click **Overview** below the journal calendar to browse daily notes together.
Choose **Week** (Monday–Sunday) or **Month**, then use **Previous**, **Next**,
**Today**, or **Refresh**. The overview initially uses the selected calendar date,
or today when no date is selected. It reads the existing `Journal/YYYY/MM/YYYY-MM-DD.md`
pages and does not create entries simply by browsing.

Each day shows a read-only Markdown preview of up to 4,000 characters. Long
entries display an excerpt notice; click a date to open the full daily page.
Clicking an empty day's date creates its daily page through the existing journal
flow. Task checkboxes are display-only. A failed entry load shows its path and
error alongside a Refresh instruction; other entries remain available.

Opening the overview first saves the current draft. Save failures or unresolved
conflicts prevent opening it and preserve the draft. Closing the overview with
**Close** or **Esc** keeps the current editor page. Changing the period or closing
the dialog ignores late responses from earlier loads. Overview navigation remains
local to the dialog and does not change the calendar selection until a date is opened.

## Pinned and recent pages

Click **☆ Pin page** in the page toolbar to add the current page to **PINNED**
in the sidebar. Click **★ Unpin page** to remove it. **RECENT** lists the last
10 successfully opened pages, newest first, without duplicates. Both lists stay
available while searching or filtering by tag, and opening a shortcut follows
the same draft-saving and conflict checks as normal page navigation.

Preferences are saved in browser storage separately for each notebook path.
They survive reloads in the same browser and origin, but are not synced between
devices or included in notebook backups. A notebook folder move uses a new key.
Renaming a page through Leaf Wiki updates its shortcuts. Missing or trashed pages
are hidden without deleting their preferences, so restoring the same path makes
them visible again. Renames performed outside Leaf Wiki are not tracked.

Storage failures appear beside the shortcuts; editing remains available and
shortcut changes remain in memory for the session. Each successful write is
read back and verified. Invalid saved shortcut data is preserved for repair,
and is never silently replaced. Follow the diagnostic to repair or remove that
browser storage entry, then reload. Failed writes can be retried by pinning or
opening a page after enabling storage or freeing space.

## Markdown tables

Use a header row followed by a separator row with at least three hyphens per
column. Outer pipes are optional. Colons select left, center, or right alignment:

```markdown
| Feature | Status | Effort |
| :--- | :---: | ---: |
| **Tables** | Ready | Medium |
| [[Home]] | Reference | Small |
```

Tables appear in preview and standalone HTML exports. Wide tables scroll
horizontally. Cells support the existing inline Markdown, including wiki links,
code, emphasis, and images. Write `\|` for a literal pipe; pipes inside code spans
and wiki-link labels also stay inside their cell. Body rows must contain a pipe;
missing cells are filled with empty cells and extra cells are ignored. A blank
line or another block ends the table. Malformed separators remain ordinary text,
and table syntax inside code blocks is displayed literally. Raw HTML stays text.

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
While the editor is idle, Leaf Wiki checks the open page's revision every five
seconds and flags an external edit without refreshing the whole notebook. Other
pages are rescanned on notebook requests, with full scans coalesced to at most
once per second; the open page is always read directly. Reloading the file
requires confirmation.

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

## Image captions and sizing

Open **Image options** in the page toolbar, choose a local image occurrence, enter
a caption, and select **Small**, **Medium**, or **Full width**. The image at the
editor cursor is selected when possible. Repeated occurrences can have different
settings. **Apply** updates only that image's Markdown, preserving its link, alt
text, and surrounding content. Changes use normal draft recovery and autosave;
**Undo format** can revert the latest change. Cancel and reopen the dialog if the
editor changes while it is open.

Settings use this Leaf Wiki Markdown extension immediately after the image:

```markdown
![Diagram](Design.attachments/example.png){width=medium caption="Storage architecture"}
```

Small is 240px, Medium is 480px, and Full uses the available width. All sizes are
clamped to the containing pane; aspect ratio is preserved. Captions render below
the image as plain text, including in HTML exports and journal overviews. They
do not interpret HTML or inline formatting. Images without this extension retain
their existing natural sizing. Page rename, folder moves, and revision restoration
preserve the settings while adjusting owning-page attachment references.

Captions are optional and limited to 500 UTF-16 code units, matching browser input
limits. The caption value is a JSON string, so quotes and backslashes are escaped.
The dialog also escapes Markdown metacharacters with JSON Unicode escapes to
avoid table-cell splitting and accidental wiki-link/tag parsing in metadata.
For example, a caption containing a pipe uses `\u007c` in its stored string.
Malformed options remain visible as literal source text and show an image tooltip
diagnostic; repair them in Markdown before editing through the dialog. Image
options do not apply to code examples, remote images, or unsupported image paths.

## Notebook backup and restore

Open **Backup** in the header and choose **Download notebook backup**. This
downloads `LeafWiki-backup.json`, a versioned Leaf Wiki bundle containing regular
notebook files, images, revision history, and trash. Each file includes its size
and SHA-256 checksum. UTF-8 files are stored as text; binary files use hexadecimal
encoding. This is a restorable JSON bundle, not a ZIP file or HTML export.
Runtime lock files and temporary writes are excluded. Search caches and browser
preferences are not notebook files and are not included. Empty directories are
not preserved; required directories are recreated from file paths.

Choose a downloaded JSON file, click **Validate backup**, and enter a **new folder
name beside the current notebook**. Click **Restore** and confirm. The destination
must not exist, even as an empty folder. Folder names use one portable component
of at most 120 UTF-8 bytes. The server validates paths, checksums, duplicate names,
file/directory collisions, and size limits before creating the destination.
Every restored file is read back and checked before success is reported.

Restoring keeps the current notebook open and never overwrites it. After success,
the dialog shows the verified destination path. Stop Leaf Wiki and restart with
`--data-dir "<restored path>"` to open it; add `--save-config` if desired. The usual
startup rebuilds its search index. Server-console progress identifies files being
backed up or restored; the dialog remains busy until the operation finishes.

A failed or interrupted restore may leave a new partial folder. Preserve it for
inspection and retry using a different new folder name. A partial restore keeps
`.leaf/restore-incomplete.json`; startup refuses to open that folder. Do not remove
the marker to bypass the check. Write and verification errors retain the selected
backup and destination name in the dialog and never report successful restoration.

Bundles are limited to 10,000 files, 32 MiB of decoded file contents, and 63 MiB
of JSON. For larger notebooks, copy the entire notebook folder with your normal
backup tooling. Symlinks, reparse points, and non-portable names stop backup with
a diagnostic rather than silently omitting data. Pending maintenance recovery and
incomplete restores also block backup. Visible external file changes during
backup abort it; pause external editors and sync writes for a consistent snapshot.
The checks cannot coordinate cloud synchronization or eliminate every possible
external-write race. Keep the downloaded bundle as a separate copy.

## Attachment manager

Click **Attachments** in the header to browse PNG, JPEG (`.jpg`), GIF, and WebP
files belonging to active pages. Opening the manager first saves the editor's
draft; save failures or conflicts keep the editor intact and prevent opening.
Each row shows an image preview, its owning page, its byte size, and whether the
current saved Markdown references it. Click the owner to open that page. Close
or Esc returns to the current editor without navigating.

**No current reference** does not mean an image is safe to delete: revision
history is not scanned. This manager is read-only and provides no cleanup action.
Trash attachments and directories without active owner pages are excluded.
References inside code are excluded. Missing referenced images appear with a
diagnostic instead of a preview. Oversized, unreadable, or invalid image previews
also show errors. Use **Refresh** after inspecting or repairing a reported file.

Files are discovered only inside each active page's own attachment directory;
symlinks and Windows reparse points are excluded. Supported names match the
existing image-serving rules; unsupported filenames and formats are omitted.
Results display 40 rows at a time; **Show more** reveals the next group. Scans are
limited to 2,000 images per page and 10,000 images overall, with an explicit error
rather than a silently truncated listing. Sizes are gathered as file metadata
without loading every image into memory. Image previews retain the 5 MiB limit.

## Rename and trash

**Rename** moves a single page, updates incoming wiki links, and preserves its
outgoing relative links and images. Child pages remain at their existing paths;
  use **Move folder** for a subtree move. A destination page or attachment-directory
collision is rejected.

**Trash page** removes one page and its images from the active notebook. Child
pages remain. Open **Trash** to restore it. Restoration rejects occupied page
paths or attachment directories.

Multi-file maintenance uses a recovery journal in `.leaf/transaction.json`.
An interrupted operation is rolled back when the notebook next starts. Recovery
stops if a participating Markdown file has been edited externally; preserve the
files and journal for manual reconciliation. The notebook uses a local advisory
lock to prevent two Leaf Wiki servers from opening the same folder on one device.

## Move folder

Click **Move folder** in the header, enter **From** and **To** namespaces, and
choose **Preview move**. The preview counts affected pages, supported images,
and outside pages whose incoming wiki links will be updated. **Move folder** then
asks for confirmation. Preview and confirmation first save the current draft;
failures retain it and keep the entered folder names. The current page reopens
at its new path after a successful move, and pinned/recent shortcuts follow it.

The folder's own page, if present, and every descendant page move together.
Paths match whole namespace components: moving `Projects/Wiki` does not affect
`Projects/Wikipedia`. Wiki links are resolved against their original source and
rewritten in one pass, preserving labels and heading anchors. Relative links to
pages outside the subtree keep their original targets; missing targets inside
the subtree follow its new namespace. Code blocks and inline code stay literal.
Each owning page's attachment directory moves with it, and image references are
updated when its name changes. Revision history follows the move; restoring an
older version also relocates wiki targets that participated in the move.

Source and destination must not overlap. Existing pages anywhere in the target
namespace, occupied destination image directories, and invalid names are rejected.
Existing empty directories can be reused, and unrelated non-page files are left
in place. Empty source directories may remain. Orphan attachment folders without
active owner pages do not participate. Saved search queries and browser drafts for
inactive pages are not rewritten; inspect those separately after a folder move.

The preview token covers notebook page revisions, affected history manifests,
and image metadata. Changes before confirmation require a new preview. Planning
and the recovery journal each have a 32 MiB limit; move smaller folders if needed.
The transaction journal covers every changed page, attachment directory, and
destination history manifest. Failures roll back; interrupted operations recover
on startup. Recovery stops on conflicting external edits or attachment collisions
and preserves the journal for inspection. Pause external writers during a move;
revision checks cannot eliminate the final filesystem race with independent tools.

## Zim desktop wiki import

Convert an existing Zim Desktop Wiki notebook into a Leaf Wiki Markdown notebook
using the built-in migration utility. The converter preserves wiki hierarchy,
translates Zim formatting, normalizes task checklists, and copies page-level
image attachments into Leaf Wiki's `<Page>.attachments/` structure.

Run the converter standalone or via `wiki_web.lua`:

```sh
# Standalone CLI utility:
luajit wiki_web/zim.lua <path/to/zim_notebook> <path/to/destination_leaf_wiki>

# Integrated via wiki_web.lua:
luajit wiki_web.lua --import-zim <path/to/zim_notebook> --data-dir <path/to/destination_leaf_wiki>
```

Supported conversions:

- **Headers**: Zim RFC822 metadata (`Content-Type: text/x-zim-wiki`, `Wiki-Format`,
  `Creation-Date`) are cleanly stripped from page text.
- **Headings**: Zim's inverted heading hierarchy (`====== Heading 1 ======` down
  to `== Heading 5 ==`) translates to standard Markdown `#` down to `#####`.
- **Text formatting**: `**bold**`, `//italic//`, `~~strikethrough~~`, `__underline__`
  (`<u>text</u>`), inline verbatim `''code''` (`` `code` ``), and fenced code blocks
  `'''lang ... '''` (```` ```lang ... ``` ````).
- **Checklists & tasks**: Open tasks `[ ]` become `- [ ]`; completed tasks `[*]`,
  `[x]`, and `[X]` become `- [x]`; cancelled tasks `[-]` become `- [x] ~~task~~`.
- **Wiki links**: Page links `[[Page]]`, subpage links `[[+Subpage]]` (resolved to
  `[[CurrentPage/Subpage]]`), root links `[[:Root]]` (`[[Root]]`), and labeled
  links `[[target|label]]` are preserved. External web links `[[http:...|Label]]`
  become Markdown `[Label](http:...)`.
- **Image attachments**: Zim image tags `{{image.png?width=300}}` translate to
  Leaf Wiki Markdown `![](image.png){width=300}`. Associated image files
  (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`) are copied into corresponding
  `<Page>.attachments/` folders.

The importer operates non-destructively: original Zim notebooks are never modified.

## Limits and compatibility

Pages are limited to 1 MiB, names to 240 UTF-8 bytes, nesting to 16 components,
and notebook indexing to 2,000 pages. Names cannot contain control characters,
backslashes, wiki syntax delimiters, hidden components, or `.attachments`
components. Notebook symlinks are not followed. Invalid or oversized existing
pages produce an error so they can be corrected externally. On Windows, junctions
and other reparse points are also excluded. Windows device names, reserved
filename characters, and names ending in a dot are rejected; the spelling and
case of existing filenames must match exactly to prevent duplicate index entries.

The app does not read Zim's wiki-text format directly at runtime. Use the built-in
Zim importer (`--import-zim` or `wiki_web/zim.lua`) to convert Zim notebooks into
Leaf Wiki Markdown notes. Existing `.md` files can be placed in the notebook and
indexed automatically.

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
luajit wiki_web/tests/test_zim.lua
python3 wiki_web/tests/test_linux_http.py
node --test wiki_web/tests/test_http.js wiki_web/tests/test_ui.js wiki_web/tests/test_theme.js
node --check wiki_web/static/app.js
node --check wiki_web/static/markdown.js
node --check wiki_web/static/export.js
node --check wiki_web/static/theme.js
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
