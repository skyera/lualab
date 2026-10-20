# Leaf Wiki (`wiki_web`) Review: Improvement Opportunities

Date: 2026-10-20
Scope: `wiki_web/` backend, `wiki_web/static/` frontend, and the shared
`dictionary_web/` HTTP/DB modules it uses.
Status: Items 1–2 were implemented and verified on 2026-10-20. Item 3 was
resolved with item 1. Items 4–8 remain proposals.

## Summary

| # | Improvement | Impact | Effort |
|---|---|---|---|
| 1 | Incremental index sync instead of full rescans | Save drops from ~275 ms to ~25 ms; idle poll from ~220 ms to <1 ms at 1,000 pages | M |
| 2 | Linear HTTP request-body intake | 32 MiB body drops from ~33 s to tens of ms | S |
| 3 | Do not re-render the UI on the idle poll | Removes preview re-parsing and sidebar focus loss every 5 s | S |
| 4 | Broken-link dashboard | New view backed by data already in the index | S |
| 5 | Revision comparison in History | Completes the existing revision workflow | M |
| 6 | Disk hygiene: stale temp files, empty trash | Prevents unbounded growth and crash leftovers | S–M |
| 7 | Optional FTS5 search index | Keeps search latency bounded on large notebooks | M |
| 8 | Portable page-name validation on Linux | Aligns page creation with backup portability rules | S |

Effort is relative: S is under half a day, M is one to two days.

## Method and measurements

Benchmarks ran on Windows 10/11 with LuaJIT 2.1, a warm filesystem cache, and a
synthetic notebook of 1,000 pages. Each page was 668 bytes of Markdown
containing a wiki link and a tag. Timings used `GetTickCount64`.

Notebook operations (`Notebook.open`, repeated `Notebook:state`, one `page`):

| Operation | Result |
|---|---|
| Initial open and index build | 375 ms |
| `Notebook:state()` samples | 218, 250, 235, 218, 235 ms |
| Single `Notebook:page(id)` | <1 ms |

The request-body numbers below come from an isolated reproduction of the exact
loop in `dictionary_web/http.lua`, not from an end-to-end HTTP round trip. They
measure the string-copy cost alone.

| Body size | `body = body .. chunk` | Collect chunks + `table.concat` |
|---|---|---|
| 4 MiB | 531 ms | <1 ms |
| 8 MiB | 1,781 ms | 16 ms |
| 16 MiB | 7,718 ms | 16 ms |
| 32 MiB | 33,203 ms | 31 ms |

Caveats: real pages are often larger than 668 bytes, which increases hashing
cost per page; absolute timings vary by disk. The scaling behavior is the
important result.

## 1. Full index rescan on every save and every poll

### Evidence

`Notebook:sync()` (`wiki_web/notebook.lua:86`) lists the notebook and then
reads and SHA-256-hashes **every page** (`notebook.lua:90-101`). It does not
compare metadata first; unchanged pages are read in full just to learn that
their revision did not change.

`sync()` is called from:

- `Notebook:state` (`notebook.lua:129`), used by `GET /api/state`
- `Notebook:backlinks` (`notebook.lua:175`)
- `Notebook:graph` (`notebook.lua:180`)
- `Notebook:tasks` (`notebook.lua:215`)
- `Notebook:attachments` (`notebook.lua:278`)
- `Notebook:save` (`notebook.lua:338`), so every autosave
- rename, trash, restore, and folder move paths

On the client:

- typing schedules `save` after 650 ms (`static/app.js:1734`);
- `checkExternal` runs every 5 seconds (`static/app.js:2655`) and calls
  `refresh()` (`app.js:2636`), which calls `/api/state` (`app.js:1591`);
- opening the dashboard requests `/api/state`, `/api/attachments`, and
  `/api/tasks` together (`app.js:150`), so it performs three independent full
  scans.

The server is single-threaded, so each scan also delays static assets and other
requests.

### Proposed change

1. Add `Notebook:sync_page(id)` that:
   - reads the one page and computes its revision;
   - upserts the `pages` row only when the revision changed;
   - deletes and re-inserts that page's outgoing `links`;
   - updates `self.page_tags[id]` (and removes it when the page is gone).
2. Call `sync_page` from `save`, `capture`, `update_task`, and
   `restore_version` (all funnel through `save`). Keep full `sync()` for
   rename, trash, restore, and folder move, where many pages can change.
3. Coalesce read-endpoint scans: `state`, `tasks`, `attachments`, and `graph`
   can reuse the last full scan for a short interval (for example 1,000 ms)
   instead of rescanning per request.
4. Add `GET /api/revision?id=<page>` that reads and hashes only that page and
   returns `{ id, revision }` (404 when missing). Have `checkExternal` poll that
   endpoint and call `refresh()` only when the open page's revision differs.

Expected result at 1,000 pages: autosave reduces to the page write plus history
fsync (tens of milliseconds), idle poll under 1 ms, dashboard one scan instead
of three, and no server-wide stall while typing.

### Sketch

```lua
-- notebook.lua
function Notebook:sync_page(id)
    local page = self:page(id)
    local current = self.db:query('SELECT revision FROM pages WHERE id=?', { id })[1]
    if not page then
        if current then
            self.db:query('DELETE FROM pages WHERE id=?', { id })
            self.db:query('DELETE FROM links WHERE source=?', { id })
            self.page_tags[id] = nil
        end
        return
    end
    if not current or current.revision ~= page.revision then
        self.db:query([[INSERT INTO pages VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            title=excluded.title,content=excluded.content,revision=excluded.revision]],
            { id, page.title, page.content, page.revision })
        self.db:query('DELETE FROM links WHERE source=?', { id })
        for target in pairs(links.targets(id, page.content)) do
            self.db:query('INSERT INTO links VALUES(?,?)', { id, target })
        end
    end
    self.page_tags[id] = page.tags
end
```

```lua
-- Notebook:save
self.fs:write(id .. '.md', content)
self:sync_page(id)              -- was: self:sync()
return self:page(id)
```

```js
// static/app.js
async function checkExternal() {
  if (state.loading || state.uploading || state.saving || $('search').value || anyDialogOpen()) return;
  const page = state.page;
  if (!page) return;
  try {
    const { revision } = await api('/api/revision?id=' + encodeURIComponent(page.id));
    if (state.page !== page || revision === page.revision) return;
    await refresh();
    if (state.page === page && page.revision !== revision) {
      state.blocked = true;
      $('conflict').hidden = false;
      status('File changed · Reload needed', true);
      message('This page changed outside Leaf Wiki. Your editor content is preserved.');
    }
  } catch (error) { message(error.message); }
}
```

### Implementation result (2026-10-20)

Implemented `Notebook:sync_page`, `Notebook:sync_if_stale`, `GET /api/revision`,
and revision-only idle polling. On the same 1,000-page benchmark, a full
`sync()` took 234–250 ms while `sync_page()` stayed below the timer resolution.
A full save averaged 25 ms, dominated by history snapshot fsyncs, instead of
roughly 275 ms. Coalesced `state()` calls took 0–15 ms. The notebook, HTTP, and
UI suites pass.

### Verification

- Repeat the benchmark before and after: time `save` and `state` on a
  1,000-page notebook. Acceptance: the revision poll stays under 5 ms, save
  stays within the page-write plus history-fsync cost, and a second `state`
  within the coalescing window does not rescan.
- Assert correctness: saving a page updates its tags and outgoing links; saving
  a page with a link to a new target makes that target appear in `backlinks`;
  deleting/trashing removes its `links` rows.
- HTTP tests: `/api/revision` for existing, unchanged, changed, and deleted
  pages; concurrent save plus revision poll; dashboard still shows current
  counts.

## 2. Quadratic request-body accumulation

### Evidence

`dictionary_web/http.lua:194` appends each received chunk to a Lua string:

```lua
body = body .. ffi.string(chunk, bytes)
```

Each append copies the entire accumulated body. The measured 32 MiB case takes
33 seconds of pure copying. This affects:

- image uploads up to 5 MiB (`/api/image`);
- backup validation and restore up to 64 MiB
  (`/api/backup/validate`, `/api/backup/restore`, limits set in
  `wiki_web/app.lua`).

Header accumulation at `http.lua:175` uses the same pattern but is capped at
16 KiB, so it is harmless.

### Proposed change

Receive into a preallocated FFI buffer and convert once:

```lua
local rest = buffer:sub(header_end + 4)
local body = ffi.new('char[?]', math.max(request.length, 1))
local filled = math.min(#rest, request.length)
if filled > 0 then ffi.copy(body, rest, filled) end
while filled < request.length do
    if now_seconds() >= deadline or not readable(fd, 1000) then
        return nil, 'Request timed out.', 408
    end
    local bytes = tonumber(C.recv(fd, body + filled, request.length - filled, MSG_DONTWAIT))
    if bytes <= 0 then
        return nil, 'Incomplete request body.', 400
    end
    filled = filled + bytes
end
request.body = ffi.string(body, request.length)
```

The buffer is bounded by the existing per-route `body_limits`, so memory use
remains capped.

Optionally, avoid building `headers .. body` in `M.respond` for large
responses by sending the header frame and body in two loops; this removes one
full-body copy on backup downloads.

### Implementation result (2026-10-20)

`read_request` now receives directly into a preallocated FFI buffer and
converts once. A new HTTP regression test posts a valid 16 MiB backup bundle
(including Node's JSON serialization, server-side JSON parsing, SHA-256
verification, and validation) in ~1.1 s end to end, bounded at 4 s. The
isolated 16 MiB concatenation cost of 7.7 s is gone.

### Verification

- Time POSTs of 4, 8, 16, and 32 MiB against the real server; acceptance:
  roughly linear and under 200 ms for 32 MiB.
- Confirm the 413 path still rejects bodies over each route's limit, and that
  partial/timeout requests still return 400/408.
- Regression tests for image upload and backup validate/restore.

## 3. Idle poll rebuilds the whole UI

### Evidence

`refresh()` (`static/app.js:1590`) updates state and then unconditionally calls
`renderTagFilter()`, `renderTree()`, `renderJournal()`, and `preview()`
(`app.js:1594`). `checkExternal` runs it every 5 seconds while idle.

Consequences:

- the full Markdown preview is re-parsed every 5 seconds, even if nothing
  changed;
- `renderTree()` and `renderJournal()` use `replaceChildren`, so keyboard focus
  inside the sidebar or calendar is lost every poll;
- a 1 MiB page pays a full parse repeatedly for no reason.

### Proposed change

Use the `/api/revision` endpoint from item 1 and only call `refresh()` when the
open page actually changed. For changes elsewhere, refresh on user actions
(navigation, search, explicit refresh) as today. If a notebook-wide poll is
still desired, return a cheap fingerprint (page count plus max revision or a
write counter) and skip all rendering when it matches the previous value.

### Implementation result (2026-10-20)

Resolved with item 1: `checkExternal` now polls `/api/revision` for the open
page and calls `refresh(true)` only when that revision changed. The idle poll
no longer fetches notebook state or rebuilds the tree, calendar, and preview.

### Verification

- With the network panel open, idle for 30 seconds: only `/api/revision`
  requests should appear.
- Tab to a sidebar page button and idle 10 seconds; focus must remain.
- Change a page externally while it is open: the conflict banner must still
  appear within the poll interval.
- Change a different page externally: it must appear on the next navigation,
  search, or manual refresh.

## 4. Broken-link dashboard

### Evidence

`links.targets()` already resolves links and `Notebook:sync()` stores every
target, including missing pages, in the `links` table. No new scanning is
needed.

```sql
SELECT l.target, l.source
FROM links l
LEFT JOIN pages p ON p.id = l.target
WHERE p.id IS NULL
ORDER BY l.target, l.source;
```

### Mockup

```text
┌─ Broken links ──────────────────────────────────┐
│ Target                    Referenced by         │
│ Projects/Old-Plan   (2)   Home, Daily/2026-10-18│
│ Ideas/Unwritten     (1)   Projects/Wiki         │
│                                                 │
│ [Create page]  [Open source page]               │
└─────────────────────────────────────────────────┘
```

Place it in the Dashboard as a new section, with a count and a "View all"
expansion when the list is long. Clicking a target creates the page through the
existing `+ Page` flow, pre-filled with that name; clicking a source opens the
page.

### Verification

- Two sources linking one missing target produce one grouped row with both
  sources.
- A target created later disappears after refresh.
- Links inside code fences and inline code are not reported.
- Valid links, self-links, and external URLs are excluded.

## 5. Revision comparison in History

### Evidence

`History` already returns full snapshot text (`wiki_web/history.lua:112`), and
the dialog shows a raw preview (`static/index.html`, `#history-preview`). There
is no diff, so users must compare by eye before restoring.

### Mockup

```text
History
┌ Versions ─────────┬ 2026-10-18 14:02 ─────────────┐
│ 2026-10-18 14:02   │  # Home Lab                  │
│ 2026-10-17 09:11 ◀ │ -Old: 4 disks                 │
│ 2026-10-15 18:44   │ +New: 6 disks                 │
│                    │  -[ ] Enable IPv6            │
│                    │ +[x] Enable IPv6             │
└────────────────────┴──────────────────────────────┘
  +2 added  −2 removed       [Restore this version]
```

### Proposed change

Add a client-side line diff in a small `static/diff.js` (or inside
`markdown.js`) and render added/removed lines with classes in the existing
preview pane. Use a line-based algorithm with a common-prefix/suffix
fast path; avoid a full O(n²) LCS over very large files by capping the
comparison (for example 20,000 lines per side) and falling back to a plain
preview with a notice.

### Verification

- Added, removed, and unchanged lines; empty to content; content to empty.
- CRLF, Unicode, emoji, and a single very long line.
- Large-file cap shows the fallback notice instead of freezing.
- Restore still uses the existing revision checks; diff never mutates data.

## 6. Disk hygiene

### Stale temporary writes

`Fs:write` creates `.leaf-write-<pid>-<serial>` next to the target and removes
it on handled failure (`wiki_web/fs.lua`, `wiki_web/fs_windows.lua`). A process
crash leaves these files behind. Backup excludes them, but nothing cleans them.

Fix: at notebook open, under the notebook lock, remove files matching
`.leaf-write-%d+-%d+` (optionally only those older than an hour). Report the
count in the startup progress output.

### Empty trash

Trash entries and `.leaf/trash` files are never removed after restore, and
there is no permanent delete. Add:

- **Delete forever** per trashed entry, with an explicit confirmation;
- **Empty trash**, requiring a typed confirmation;
- a clear statement that history is unaffected by trash deletion.

Verification: deleting a trashed page removes its `.md` and `.attachments`
directory; a failed move leaves the entry intact and visible; concurrent
restore/delete conflicts are rejected through the existing journal.

## 7. Optional FTS5 search

Search builds `content LIKE '%term%'` queries (`notebook.lua:140-160`), which
scan every page's full content on each search request (debounced 120 ms in the
client). Page content is capped at 1 MiB and the notebook at 2,000 pages, so
the worst case is large.

`dictionary_web/db.lua` and `wiki_web/sqlite.lua` already support probing FTS5
(`require_fts5`), but wiki_web never enables it. Proposed: create an FTS5 table
when the selected SQLite build supports it, keep the existing `LIKE` path as a
fallback, and rebuild the FTS index from the same scan that populates `pages`.
Because FTS5 is optional (`--sqlite-list` does not require it), startup must
log which path is active.

Verification: identical result sets for the same queries on both paths;
snippets still highlight terms; index rebuild after a cache delete; a build
without FTS5 still starts and searches.

## 8. Portable page-name mismatch on Linux

### Evidence

`links.page_id` rejects `<>"|?*`, trailing spaces/dots, and reserved device
names only on Windows (`wiki_web/links.lua`, Windows branch). On Linux those
names are accepted. `backup.valid_path` (`wiki_web/backup.lua`) rejects
`[<>:"|?*]` and names ending in a space or dot on **every** platform.

Result: a Linux user can create `Plan?.md` or `Notes..md` normally, then
discover that **Download notebook backup** refuses to run because the path is
"non-portable".

### Options

1. Enforce portable names in `page_id` on all platforms, with a clear creation
   error (simplest, but rejects pages that already exist).
2. Keep permissive naming and add a pre-backup report listing offending pages,
   with guidance to rename them (more work, no data loss).

Recommendation: option 1 for new pages, plus a startup warning for existing
non-portable `.md` files so they can be renamed before the first backup.

Verification: create `Plan?`, `Notes.`, and `CON` pages on Linux; creation must
fail with a specific message. An existing `Plan?.md` must still be readable and
must produce the documented backup diagnostic.

## Smaller fixes

- `dictionary_web/http.lua:100` has no reason phrase for 503, so disabled
  dictionary responses read `HTTP/1.1 503 Error`. Add `[503] = 'Service
  Unavailable'`.
- Static assets are served with `Cache-Control: no-store`
  (`http.lua:233`), so `app.js` (132 KiB), `style.css`, and the other assets are
  re-downloaded on every load. Serve them with an ETag or
  `max-age=0, must-revalidate`; keep `no-store` for API responses.
- The image-reference rewrite regex is duplicated in three places in
  `notebook.lua` (`restore_version`, `rename`, `folder_plan`). Extract one
  helper in `links.lua`.
- `wiki_web/FEATURE_RECOMMENDATIONS.md` is untracked and stale: most items it
  recommends already ship per `README.md`. Update or remove it before the next
  documentation commit.
- `static/app.js` is 2,655 lines. Splitting it would help maintenance, but the
  UI tests evaluate the file in a VM and truncate it at `start();`
  (`tests/test_ui.js:579-582`), so any split requires updating the test
  harness. Low priority.

## Verification plan

Run from the repository root after any change:

```sh
node --test wiki_web/tests/test_http.js wiki_web/tests/test_ui.js wiki_web/tests/test_theme.js
node --check wiki_web/static/app.js
node --check wiki_web/static/markdown.js
node --check wiki_web/static/export.js
node --check wiki_web/static/theme.js
```

On Linux, also run:

```sh
luajit wiki_web/tests/test_notebook.lua
luajit wiki_web/tests/test_zim.lua
```

On Windows, the HTTP suite runs the notebook unit tests and cleans their
temporary folders. Do not treat the standalone Lua command as a Windows check.

Performance acceptance:

- 1,000-page notebook: save and `/api/revision` under 10 ms; `/api/state`
  coalesced within the poll window.
- 32 MiB POST body handled in under 200 ms server-side.
- Idle 30 seconds: one cheap request per interval, no preview re-parse, no
  sidebar focus loss.

Feature acceptance:

- Broken-link grouping and navigation.
- Diff correctness across empty, CRLF, Unicode, and large-line inputs.
- Trash deletion with failure rollback.
- Backup still succeeds for portable names and reports non-portable ones.

## Recommendation

Implement items 1–3 first as one performance patch: they are internal changes
with the largest measured payoff and no user-facing contract changes. Then item
4 (small and immediately useful), then item 5. Items 6–8 are independent
patches suitable for separate commits.

Items 4–8 remain proposals.
