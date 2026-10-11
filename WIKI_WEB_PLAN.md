# Leaf Wiki — Plan and Design

Status: initial implementation available in `wiki_web.lua` and `wiki_web/`.
See [the runtime guide](wiki_web/README.md) for supported behavior, configuration,
limits, and verification commands. Subtree moves, Zim import, and the later
additions below remain future work.

## Purpose

Build a local personal wiki inspired by Zim, with a browser interface and a
LuaJIT backend. Make writing, linking, finding, and organizing notes quick while
keeping the notebook readable outside the application.

- App name: **Leaf Wiki**.
- Launcher: **`wiki_web.lua`**.
- Supporting code and browser assets: **`wiki_web/`**.
- Intended launch command: `luajit wiki_web.lua`.
- Start with a single-user notebook served on localhost.

## Recommended first release

| Feature | Behavior |
| --- | --- |
| Pages and notebook tree | Create and browse nested pages, such as `Projects → Wiki → Design`. |
| Editor and preview | Write Markdown; toggle preview or use a split editor/preview layout. |
| Wiki links | Use `[[Page name]]`; offer to create a page when its target does not exist. |
| Backlinks | List pages that link to the current page. |
| Search | Search titles and content; jump to pages from the keyboard. |
| Safe autosave | Display Saving, Saved, or Save failed; preserve unsaved edits on failure. |
| Rename and trash | Update internal links on rename; restore pages from trash. |

Prioritize pages, wiki links, search, backlinks, and safe autosave. Add features
only after those workflows are reliable.

## Interface mockup

```text
My notebook          [ Search pages… ]       [+ Page]

Home                 Projects / Wiki / Design
Journal              [Edit] [Preview]           Saved
▾ Projects
  ▾ Wiki             # Design
    Design           A personal notebook built with Lua.
    Tasks
Reading              Related: [[Projects:Wiki:Tasks]]
Ideas
                     Backlinks
                     • Projects:Wiki
```

On narrow screens, collapse the notebook tree into a drawer and show either the
editor or preview. Keep the page title, navigation, and save status visible.
Support keyboard navigation and accessible labels for controls.

### Core interactions

1. Select a page from the tree or search to open it.
2. Edit its Markdown and see a clear save-state indicator.
3. Follow an existing wiki link to navigate to its target.
4. Follow a missing link to create the target page after an explicit action.
5. Use backlinks to trace related notes.
6. Rename or move a page through an explicit command that updates internal links.
7. Move deleted pages to trash and allow restoration.

Do not silently discard unsaved edits when switching pages. A stale save response
must not mark newer text as saved or replace the currently open page.

## Storage and architecture

Use **Markdown files as the source of truth**. Use SQLite for a **rebuildable
search and link index**, rather than making it the only copy of page content.
This supports external editors, normal filesystem backups, and Git.

Illustrative notebook structure:

```text
notebook/
  Home.md
  Projects/
    Wiki.md
    Wiki/
      Design.md
      Tasks.md
      Design.attachments/
        sketch.png
  Journal/
    2026-10-11.md
  .leaf/
    index.db
    trash/
```

The attachment directory convention is provisional. Keep attachments near their
pages, and move or restore them together with their owning page.

Suggested responsibilities:

| Component | Responsibility |
| --- | --- |
| Launcher | Parse configuration and start the application. |
| Notebook storage | Read files, validate paths, save atomically, rename, and manage trash. |
| Markdown and links | Render supported Markdown and resolve wiki links consistently. |
| SQLite index | Index titles, content, outgoing links, and backlinks; rebuild from files. |
| HTTP API | Expose page, search, link, and notebook operations. |
| Browser UI | Manage editing, preview, navigation, and save state. |

Use the repository's existing LuaJIT/FFI HTTP and SQLite work as reference.
Assess which parts can be reused without coupling the wiki to Wordbook data or
its dictionary-specific routes.

## Design decisions to settle before implementation

- **Zim compatibility:** determine whether importing existing Zim notebooks is
  required. Zim stores its own wiki-text format; Markdown storage needs an
  importer rather than assuming compatibility.
- **Link addressing:** define absolute and relative page links, namespace
  separators, labels, anchors, and how ambiguous titles resolve.
- **Page identity:** decide how titles map to filenames, including Unicode,
  case collisions, and filesystem naming restrictions.
- **Markdown support:** choose and verify a renderer; define supported syntax
  and how wiki links integrate with it.
- **External edits:** detect changes made by another editor and rebuild affected
  index entries. Warn about conflicts rather than overwriting them.
- **Autosave:** use revision checks and atomic file replacement; distinguish a
  successfully persisted revision from subsequent unsaved typing.
- **Rename:** define subtree moves, attachment handling, and recovery if updating
  multiple files fails midway. Rewrite parsed internal links, not arbitrary text
  or code blocks.
- **Deletion:** define trash naming and restore behavior when the original path
  is already occupied.
- **Notebook paths:** contain file operations within the selected notebook;
  handle traversal attempts and symlinks explicitly.
- **Preview:** render untrusted Markdown safely, including links and attachments.

## Implementation sequence

### Phase 1 — Reliable writing

- Create the launcher and notebook configuration.
- Implement page listing, loading, creation, and atomic saves.
- Add the notebook tree, Markdown editor, and save-state feedback.
- Add revision conflict handling and protection for unsaved edits.

### Phase 2 — Wiki navigation

- Add preview and consistently resolved wiki links.
- Add explicit creation of missing link targets.
- Build the SQLite search and link index.
- Add title/content search, backlinks, and keyboard page navigation.

### Phase 3 — Notebook maintenance

- Add rename/move operations and internal-link updates.
- Add trash and restoration.
- Support external file changes and index rebuilding.
- Verify responsive layouts and complete first-release workflows.

### Later additions

- **Daily journal:** open today's page with a shortcut.
- **Task overview:** collect unchecked tasks across pages.
- **Templates:** meeting notes, reading notes, and project plans.
- **Attachments:** upload, embed, and manage images and files.
- **Revision history:** inspect changes and restore previous content.
- **HTML export:** publish a notebook as static linked pages.
- **Wordbook integration:** link reading notes to saved vocabulary.
- **Zim import:** convert supported source syntax and preserve links/attachments
  if compatibility is required.

## Verification strategy

Define executable test commands once the modules and harness exist. The following
checks are required before releasing each implemented phase.

### Storage and API

- Use temporary notebooks; verify create, save, reopen, rename, trash, and restore.
- Test empty pages, long content, Unicode names, duplicate names, invalid paths,
  and missing files.
- Simulate write failures and stale revisions; prove the previous file remains
  intact and unsaved editor content remains available.
- Test rename collisions and interrupted multi-file operations.
- Verify external edits are detected and conflicting writes are rejected.
- Exercise the real LuaJIT HTTP server end to end and check clean shutdown.
- Run LuaJIT bytecode analysis for undeclared globals and global assignments.

### Links, search, and index

- Test existing and missing targets, relative/absolute links, labels, and anchors.
- Ensure link parsing and rewriting leave code blocks and unrelated text intact.
- Check backlinks after edits, renames, deletion, and restoration.
- Delete the index and rebuild it; verify equivalent search and backlink results.
- Verify search updates after both browser saves and external file edits.

### Browser workflows

- Exercise create → edit → autosave → navigate → return → reload.
- Delay and reorder responses; ensure stale loads and saves cannot overwrite
  current content or falsely report that newer edits are saved.
- Test failed saves, unsaved navigation, conflicts, and recovery.
- Simulate keyboard input and shortcuts, including text entry in the editor.
- Verify preview escaping and safe link handling.
- Check empty notebooks, long titles, Unicode content, and narrow/mobile layouts.
- Confirm editor, preview, tree, dialogs, and status/error states all render.

## References

- [Zim overview](https://www.zim-wiki.org/index.html): plain-text pages, hierarchy,
  links, attachments, and autosave.
- [Zim background and storage](https://zim-wiki.org/manual/About.html): its
  wiki-text format and editor-independent files.
- [Zim links](https://www.zim-wiki.org/manual/Help/Links.html): link navigation
  and backlinks.
