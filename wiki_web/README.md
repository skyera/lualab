# Leaf Wiki

A local personal wiki: LuaJIT serves a browser editor, Markdown files hold your
pages, and a local SQLite index supplies search and backlinks. No npm install or
Python backend is needed. The first version supports Linux x86-64.

## Run

Install LuaJIT and the SQLite, libcurl, and OpenSSL shared libraries:

```sh
sudo apt install luajit libsqlite3-0 libcurl4 libssl3
luajit wiki_web.lua
```

Open **http://127.0.0.1:8020** on the host computer, or open
`http://<host-LAN-IP>:8020` or `http://<host-name>:8020` from another device
on the network. The default
notebook is `~/LeafWiki`. The server binds to `0.0.0.0`; allow inbound TCP
port `8020` through the host firewall for LAN access. Leaf Wiki has no login,
so only enable LAN access on a trusted network. Ctrl-C and SIGTERM close the
server and index. An absolute launcher path works from any working directory.

Choose another notebook folder:

```sh
luajit wiki_web.lua --data-dir "/home/zliu/Google Drive/Leaf Wiki"
```

Save the selected path for subsequent launches:

```sh
luajit wiki_web.lua --data-dir "/home/zliu/Google Drive/Leaf Wiki" --save-config
luajit wiki_web.lua
```

Configuration lives in `$XDG_CONFIG_HOME/leaf-wiki/config.json`, or
`~/.config/leaf-wiki/config.json` when that environment variable is unset:

```json
{
  "data_dir": "/home/zliu/Google Drive/Leaf Wiki"
}
```

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

## Writing and navigation

- **+ Page** creates a page. Use `/` or `:` between namespace components, such
  as `Projects/Wiki/Design`. Pages are ordinary UTF-8 `.md` files.
- The **Journal** calendar opens or creates a daily page for the selected date.
  Entries use `Journal/YYYY/MM/YYYY-MM-DD.md` and remain regular searchable,
  linkable Markdown pages. New entries have a date-and-weekday heading, such as
  `# 2026-10-11 (Sunday)`. Opening an older default journal heading adds the
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
- Search matches page paths and content. **Ctrl K** (or Cmd K) focuses search;
  **Ctrl S** (or Cmd S) saves immediately.

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
pages produce an error so they can be corrected externally.

The app does not read Zim's wiki-text format. Existing `.md` files can be placed
in the notebook and indexed automatically. Zim import, weekly/monthly journal
views, task aggregation, revision history, and HTML export remain future work.

## Verify

From the repository root:

```sh
luajit wiki_web/tests/test_notebook.lua
node --test wiki_web/tests/test_http.js wiki_web/tests/test_ui.js
node --check wiki_web/static/app.js
node --check wiki_web/static/markdown.js
node --test dictionary_web/tests/test_http.js dictionary_web/tests/test_ui.js dictionary_web/tests/test_theme.js
```

Tests use temporary notebooks and caches. They exercise real HTTP configuration,
large pages, revision conflicts, search, links, image serving, restart persistence,
path confinement, maintenance rollback, clipboard input, save races, and LuaJIT
bytecode scoping. Verify actual browser clipboard paste and drag-and-drop on your
device, as clipboard image availability depends on the browser and source app.
