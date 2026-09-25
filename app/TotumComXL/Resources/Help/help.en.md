# Totum Commander — Complete Guide

Totum Commander is a two-panel file manager for macOS in the spirit of Total Commander. Everything below was gathered from the program itself: its menus, keys, buttons, context menus and settings. Keys use the macOS notation: ⌘ Command, ⇧ Shift, ⌥ Option, ⌃ Control, ↩ Return, ⌫ Backspace, ⇥ Tab, ⎋ Esc.

---

## 1. The Window

The window has five parts.

| Part | What it is |
|---|---|
| **Two panels** | A file list on the left and on the right. One panel is always active: the cursor lives there, and keys and menu commands apply to it. Switch with ⇥ or a click. |
| **Tunnel** | The narrow strip between the panels: quick links to folders at the top, operation buttons at the bottom. Fully customisable (section 13). |
| **Toolbar** | The top of the window: Shelf, Trash, system monitor, disk information, theme, hidden files, settings. In "Settings ▸ General ▸ Toolbar" the buttons can be shown with labels or as labels alone, and the groups set apart by a line. |
| **Footer** | Bottom of the window: F2…F9 as buttons, the Fn-mode switch and the terminal button. |
| **Menu bar** | File, Edit, View, Go, Tools, Window, Help. The menu holds **every** command of the program, and it feeds the command palette and the tunnel. |

Above each list, top to bottom: the volume bar (disks), breadcrumbs (path), tabs, the sort header. Below the list — the status bar: how many files, how many selected, how much free space.

After a change of screen resolution the window opens centred, not in a corner.

---

## 2. The Panel: File List

### 2.1. View modes (View menu, ⌘1 / ⌘2 / ⌘3, buttons on the volume bar)

| Mode | What it shows |
|---|---|
| **Detailed** ⌘1 | A table with columns. Columns are enabled in "View ▸ Columns" or by right-clicking the header: type, size, date modified, date created, date added, permissions, owner, "Origin" (on the Shelf and in the Trash). Column widths are dragged with the mouse; the header menu offers "Reset column widths" and "Auto-fit columns". Widths are remembered (setting). |
| **Brief** ⌘2 | Names only, in several columns. Column width is set in "Design". |
| **Thumbnails** ⌘3 | Picture thumbnails and icons. |

The mode can be remembered per tab ("Remember view mode" in the tab menu) or saved for every tab automatically (setting "Save view mode per tab").

### 2.2. Sorting

Click a column header to sort, click again to reverse. The same lives in "View ▸ Sort By": name, extension, type, size, date modified, date created, date added, owner, permissions; a separate "Descending" toggle.

### 2.3. Cursor and selection

**Mouse**
- Click — cursor on the file, selection cleared.
- ⌘-click — add or remove the file from the selection.
- ⇧-click — select the range from the cursor to the click.
- Double-click — open (the double-click interval is a setting).
- Force Touch on the trackpad — by setting: nothing, open, or view.
- Dragging the selection — copies to the other panel or to another program (section 4.6).

**Keyboard**

| Key | Action |
|---|---|
| ↑ ↓ | Cursor through the list. ⇧+arrows select. |
| ← → | Detailed mode: to the start and the end; brief and thumbnails: by column. |
| Home / End, PgUp / PgDn | Start, end, page. |
| Space | By setting: quick view or select the file (like Insert in Total Commander). |
| ⌘A | Select all. |
| Num + / Num − / Num * | Select by mask / deselect by mask / invert. |
| ⎋ | Clear the selection; abandon a pending "cut". |
| Edit ▸ Select files of the same type | Every file with the extension of the file under the cursor. |
| Edit ▸ Clear Selection | Same as ⎋. |

**Select by mask** (Edit ▸ Select by mask… / Deselect by mask…): `*` — any characters, `?` — one. Several masks: `*.png&*.pdf` (or via `|`, `,`, `;`). Exclude: `!copy*`. The dialog remembers recent masks.

### 2.4. Navigation

| Action | How |
|---|---|
| Open a folder, archive, file | ↩ or double-click. A file opens in its default program; a .app is launched. |
| Enclosing folder | ⌫ (by default; a setting can turn ⌫ into delete), ⌘↑, the ".." row. |
| Back / Forward in history | ⌘[ and ⌘] |
| Other panel | ⇥ |
| Home, Desktop, Documents, Downloads, Applications, Pictures, Music, Movies, Root of the disk | The "Go" menu (⇧⌘H, ⇧⌘D, ⇧⌘O, ⌥⌘L, ⇧⌘A, ⇧⌘C) or the quick links in the tunnel. |
| Favorite folders | ⌘D — the list of favourite folders. Add and remove the current one there and in the context menu. |
| Enter a .app as a folder | Context menu or "Go". |
| Follow the link | For a symbolic link — into the target's folder, cursor on the target. |
| Breadcrumbs | Click a segment to go there. Right-click: edit the path, copy the path, paste a path and go. Setting "Select all text when editing the path". |
| Refresh | ⌘R |

**Branch view** (⌃B, View ▸ Branch) — the files of every subfolder as one list, as in Total Commander. While the tree is being read a counter sits at the bottom; ⎋ interrupts. ⌃B again returns the ordinary folder.

**Hidden files** — ⇧⌘. or the toolbar button.

**Folder sizes** — ⇧⌘↩ calculates the size of every folder in the current folder. Automatic calculation is enabled in settings; the load of the background calculation (10…100 % of cores) can be limited. On slow external disks (USB 2, network) the program switches to an economy mode by itself: folder sizes are not calculated, metadata is loaded on demand.

### 2.5. Quick filter

Start typing in the panel — a filter bubble opens and the list narrows. The mask is the same as for selection: `*`, `?`, several masks separated by space/`&`/`|`, `!` to exclude, no asterisk — a fragment of the name (`png|pdf`). By Finder tags: `#red` (the beginning is enough: `#re`), `#` — any tag, `!#re` — without it.

Bubble buttons: **Select** what is shown, **Deselect**, **Invert**, **Delete** what is shown (with the usual confirmation). A mask can be **remembered** and picked from a list later. ⎋ closes the filter and restores the folder; ⌫ edits the text; arrows, ↩ and the F-keys keep working on the narrowed list.

### 2.6. What else the list shows

- **Finder tags** — coloured dots after the name. Set with the right button (Tools ▸ Tags), visible in Finder too.
- **Git state** — a letter before the name (M, A, D, R, ?, !, ·) and the branch name on a repository folder with an orange "unsaved changes" dot. Enabled in the "List" settings. Details in the program's help (⌘?).
- **Colours by file type** — names are coloured by the rules in "Settings ▸ File Colours": a mask (`*.dmg;*.pkg`), a colour for the light and the dark theme, "only for recent" with gradual fading.
- **Pictures on folders** — icons assigned to folders in Finder (setting "Show images on folders").
- **Folder icon styles** — "Catalog V3…V9" in the "Folders & Icons" settings.

### 2.7. Volume bar

Left to right: every mounted disk, iCloud Drive, the network button. Click a disk to go to its root. The **⏏** button ejects a disk; if the disk is busy in other programs or in the program itself (operations running, unsaved files) you are told and offered a forced eject. Right-click — **Disk information**: interface, file system, total, free. From the disk's interface the program picks its working mode (full speed for internal SSDs and Thunderbolt, economy for USB and network).

The network button opens a menu: **Local network** (browse computers and shares), **Connect network drive** (smb://, afp://, nfs://), **FTP disk** / **Connect to Server…** (section 11).

---

## 3. Tabs

Each panel has its own tabs. The "File ▸ Tabs" menu and the right button on a tab:

| Action | How |
|---|---|
| New tab | ⌘T, "+" on the tab bar |
| Close | ⌘W, the cross. Pinned tabs do not close. |
| Next / previous | ⌃⇥ / ⌃⇧⇥ |
| Pin / unpin | A pinned tab does not close and is narrower. |
| Rename | Your own title instead of the folder name. |
| Colour | Red, orange, yellow, green, blue, purple, custom, none. |
| Close others / all but pinned | |
| Remember / forget view mode | The tab remembers detailed/brief/thumbnails. |
| Reorder | By dragging. |

Tabs come in three kinds: a folder, a **terminal** (section 10) and a **remote connection** (section 11). The look of tabs (height, width, rounding, font, colours, opacity of the active tab) — in the "Tabs" settings.

---

## 4. File Operations

### 4.1. The basics (F-keys, footer, tunnel, "File" menu)

| Key | Operation | Details |
|---|---|---|
| F2 | Rename | Right in the list. ↩ confirms, ⎋ cancels. A name with `/` is refused. While a copy is running, F2 sends it to the queue. |
| F3 | View | Section 6. |
| F4 | Edit | Section 7. |
| F5 | Copy to the other panel | A dialog with the destination folder (any path can be typed), a "To queue (F2)" button and a "Don't show this window" checkbox. |
| F6 | Move to the other panel | The same. |
| F7 | New folder | The name is asked; not inside an archive. |
| ⇧F4 | Create text file | As in Total Commander: the name is asked, the file is made and opened in the editor at once; an existing name simply opens. |
| F8 | Delete | To the Trash, with confirmation (configurable). A single .app opens the **program uninstaller** instead (section 9.13). |
| ⇧F8, ⇧Delete | Delete, bypassing the Trash | Permanently, with a separate warning. |
| ⌦ (Forward Delete) | Delete | Like F8; with ⇧ — bypassing the Trash. |
| ⌫ | Enclosing folder **or** delete | By the setting "Backspace goes to the parent folder". |
| F9, ⌘F | Search | Section 8. |
| ⌘F5 | Pack into an archive | Section 5. |
| ⌘F9 | Unpack | Section 5. |
| ⌘I | Properties | Section 9.14. |
| File ▸ Create text file | | An empty .txt with the given name. |

Operations on several files take the selection; without a selection — the file under the cursor. The setting "Keys ▸ Selection" adds the file under the cursor to the selection (handy after ⇧+arrows, when the cursor already stands on the next row). The ".." row never takes part.

### 4.2. Name conflicts

If the file already exists at the destination you are asked: **Replace**, **Replace all**, **Make a copy** (with a "(copy)", "(copy 2)"… suffix), **Skip**, **Skip all**, **Cancel**. The size and date of both files are shown with a hint which one is newer and larger. Copying into the same folder offers to create duplicates.

### 4.3. Clipboard

⌘C copies files to the clipboard, ⌘X cuts (the paste becomes a move), ⌘V pastes into the current folder. Works with Finder in both directions. The clipboard does not work with servers and clouds — use F5/F6 there. ⎋ abandons a pending cut.

### 4.4. Undo — ⌘Z and ⇧⌘Z

Move, copy, rename, delete to the Trash and create can be undone. The "Edit ▸ Undo" item names what will come back. If something is in the way (the file has already moved, the name is taken, the folder is no longer empty) you are told, and the undo can be repeated after the cause is removed. In a text field ⌘Z still undoes typing.

### 4.5. Operation queue

The button with circling arrows in the tunnel (the number of operations is inside the icon) and "View ▸ Operation Queue". Every operation has its own progress and **Pause / Resume / Cancel / Dismiss** buttons; completed ones are cleared in one go. An interrupted network transfer can **continue from where it stopped**. Below the operations in the tunnel, mini progress bars are drawn.

Settings: **concurrent operations** (how many the queue runs at once), **speed limit** for network transfers, **remote operations straight to the queue**. The progress window asks for confirmation when cancelling (can be turned off with "don't ask"). A system notification arrives when done.

### 4.6. Drag and drop

- From panel to panel, into Finder, into another program — a copy. With ⇧ or ⌘ — a move.
- Into the program from outside — also a copy.
- The setting "Confirm drag and drop" shows a dialog before copying/moving.
- A folder dropped into the tunnel lands where it was released (section 13).

### 4.7. NTFS disks

macOS does not write to NTFS; the program can: on the first write it asks for the administrator password. It can be saved in the Keychain ("Network & NTFS" settings), after which it is not asked again. For the time of the write the disk is temporarily remounted. Archives cannot be modified directly on NTFS — copy them to a local disk.

---

## 5. Archives

An archive opens with ↩ like an ordinary folder; inside you can browse, view and edit files (edits are offered to be written back), and copy out. A nested archive inside an archive is read-only.

**Formats**: ZIP, TAR, TAR.GZ, 7Z, TAR.BZ2, TAR.XZ, TAR.ZST, TAR.LZ, TAR.LZ4, ISO, DMG.

**Pack** (⌘F5, context menu): name and destination folder, archiver, compression level, preserve paths, include subfolders, delete source files after packing, separate archives for every file, **password (AES-256)** — for ZIP the contents are encrypted and the names stay visible; for DMG everything is encrypted. The progress shows the compression ratio and the estimated result.

**Archive here** — a submenu with formats: the archive lands next to the files, no questions.

**Unpack** (⌘F9, context menu): destination folder, "create a subfolder named after the archive", "overwrite existing files". A password-protected archive asks for it; the password is kept in memory until the program quits.

**Editing an archive** — adding, deleting and renaming inside ZIP and other formats. If the format needs a full repack, you are warned with the archive size. Only ordinary local files can be added to an archive.

The pack and unpack dialogs can be turned off in the "Confirmation dialogs" settings.

**Disk images (.dmg, .cdr, .toast)**: by setting they open "as in Finder" (the installation window) or "in the panel" (mounted, and the panel goes inside). ⇧↩ always opens the other way; the same command is "Tools ▸ Open Disk Image the Other Way". An `.iso` file is judged by its contents: a real ISO opens as an archive, without mounting, while a DMG under an `.iso` name (programs are often handed out that way) takes the disk-image road.

---

## 6. View (F3) and Quick View (Space)

**F3** opens the viewer for the file under the cursor (a folder opens too — its contents are shown). With the setting "View (F3) in the opposite panel" it is embedded in the neighbouring panel, otherwise it opens as a window. **Space** — quick view: native Apple Quick Look or the built-in one "with modes" (setting). ⎋ and Space close the view.

**Modes** (switch at the top, "How to show this file"): Auto, Quick Look, Image, Text, HEX, PDF, Document, Video, Info, Font, Drawing, Book.

| What | Particulars |
|---|---|
| Images | Zoom and pan with the trackpad. The **Recognise text** button highlights the lines found, "Copy all". The **photo info** panel: size, camera, lens, shutter, aperture, ISO, date, place (open in Maps, copy coordinates), a "Clean info…" button. |
| PDF, DjVu | A page strip (show/hide), paging. |
| Documents | Word, Excel, Pages, Numbers and the rest — through the system engine. |
| Text | Encoding choice, big files are truncated for viewing, binaries suggest HEX. |
| Video and audio | Built-in player. |
| Fonts | TTF, OTF, TTC — a glyph table. |
| Drawings | DXF (text variant). |
| PostScript | Through Ghostscript. |
| Books | FB2 and EPUB: contents, notes, ← → and PgUp/PgDn turn pages, bookmarks (add, remove, rename, list), "treat this page as the first" for numbering without the cover. |

The "File N of M" line — the viewer pages through the folder's files. Files from a cloud are downloaded to a temporary copy first; a big file asks whether to download.

---

## 7. Editor (F4)

The built-in editor runs on Monaco (the VS Code engine): language highlighting, several files in tabs, find ⌘F and replace ⌘R, go to line ⌘L, word wrap ⇧⌘W, invisible characters ⇧⌘I, minimap ⇧⌘M, current-line highlight, dark / light / high-contrast theme, font and its size, language choice. ⌘S saves, ⌘W closes the tab; closing with edits asks once. Files are UTF-8 only; a file without write permission opens read-only. A file from an archive offers to be written back after ⌘S.

RTF opens in its own editor: bold, italic, underline.

With the setting "Editor (F4) in the opposite panel" the editor is embedded in the neighbouring panel. The "External editor" setting replaces the built-in one with any application.

---

## 8. Search (F9, ⌘F)

The "Advanced Search" window.

**Modes**: **By name**, **By content** (text inside files), **Spotlight** (from the macOS index, instant, looks inside PDF, Pages, Word; no regular expressions and no hidden files; can search the whole Mac), **Duplicates** (by name, by size, by SHA-256 hash).

**Conditions**: file mask, regex, where (browse folders), in subfolders, hidden files, skip (exclusion masks), size from–to, type (all, files, folders), date, **search in pictures too** (text recognition in pictures, scans and PDFs — with a cap on the number of files per search).

**Results**: name, path, size, line (for content search). Actions: **Go to** (the panel lands on the file), **Copy to…**, **Copy here**, **Delete**. A big result list is capped with a hint to refine the query.

---

## 9. Tools

### 9.1. Command palette — ⌘P
The list of every command of the program with search by substring and initials ("cf" finds "Compare folders"). ↑↓ choose, ↩ run, ⎋ close. Commands unavailable right now are grey. The plus next to a row (or ⌘↩) adds the command as a button to the tunnel; a check mark — it is already there.

### 9.2. Compare Folders…
The folder of the left panel against the folder of the right, with all subfolders. Filter "Differences / All", a mask, an exclusion mask (`.DS_Store;*.tmp`), "Compare by content", "Ignore date". Every file has an arrow — what will happen to it: → and ← copy, move (with a little bin), to the Trash, leave alone; clicking the row cycles the options, the right button picks one directly. A summary of the plan at the bottom; the **Synchronise** button shows the total and only after confirmation does anything. Deletions always go to the Trash. Detailed help — in the window ("How it works") and in ⌘?.

### 9.3. Compare Files…
Two files (two selected in one panel or under the cursor in each panel) line by line: differences highlighted, "Only differences", line wrap, ⌥↓ / ⌥↑ — next and previous difference. Binary files are compared byte by byte.

### 9.4. Checksums…
MD5, SHA-1, SHA-256 for the selected files in one pass. Copy one or all, save to a file in md5sum/shasum format, the **Verify** field: paste a sum from a website — "Matches" or "Does not match" by any of the three algorithms.

### 9.5. Split File… / Join Parts…
Cuts a file into parts of a given size (10 MB, 25 MB, 100 MB, CD, DVD or your own), names them `name.001, .002…` like Total Commander and HJSplit, puts them into the other panel's folder, optionally writes a `.sha256`. Joining finds the other parts by itself, verifies the sum and can move the parts to the Trash — only if the sum matched.

### 9.6. Multi-Rename…
Name and extension masks with tags: `[N]` name, `[N2-5]` a part, `[E]` extension, `[C]` counter (start, step, digits, letters), `[Y][M][D][h][m][s]` date and time, `[P][G][B0]` folder names, `[=tc.size]`, `[=tc.width]` metadata, `[U][L][F][f][n]` case, `[X]` clipboard. Find and replace (regex, case, first only, in extension), case of the result, `/` in the mask sorts into folders. A preview with conflict highlighting, editing a name by double-click, **Undo**, presets. The tag reference — a button in the window.

### 9.7. Rules… / Apply Rules to This Folder
A rule: conditions (name by mask, extension, kind of file, size, age by date modified/created/added, tag) and an action (move, copy, rename by mask, to the Trash, set a tag, to the Shelf, unpack), with "Where" and a subfolder by date (`yyyy/MM`). Rules are read top to bottom; a file takes the first that matches. Applying happens only on command over the current folder, with a "what will happen" list and a switch on every row. Everything can be undone with ⌘Z.

### 9.8. PDF
**Make PDF…** from pictures (page by picture size or A4 with margins, order with arrows), **Merge into one PDF…** (two or more), **Split PDF…** (every page, every N pages, chosen ranges `1-3, 7, 12-`), **Rotate Pages…** (90° right/left, 180°, all or a range, copy or replace the original). The result lands next to the first file with a mark in the name; existing files are never overwritten.

### 9.9. Convert Images…
Format (JPEG, PNG, HEIC, TIFF or keep), quality, keep photo info, size (fit into a side, fraction of the original, allow upscaling), where (next to the original with a suffix, into a subfolder, replace the original). At the bottom — the plan for every file.

### 9.10. Recognise Text…
The macOS system recogniser, no internet: pictures, scans, PDF (page by page, honouring the document's own text layer). The text can be selected, copied whole or saved as `.txt` next to the file.

### 9.11. Clean Photo Info…
Removes EXIF: only the place (GPS) or all info. A copy marked "(no info)" or overwriting the original (irreversible). The picture is not recompressed.

### 9.12. Encryption
- **Create Encrypted Vault…** — a safe-file with a size ceiling (space is taken as it fills), a password and optionally Touch ID. ↩ opens it as a folder, "Lock Vault" turns it back into a file. "Ask for the password, forget Touch ID" and "Open with Touch ID" — in the context menu.
- **Encrypt with Password (age)…** / **Decrypt…** — `.age` envelope files. The originals stay after encryption; delete them yourself. ↩ on an `.age` offers to decrypt.

### 9.13. Uninstall Program…
The command "Tools ▸ Uninstall Program…" or F8 on a single `.app` (or the folder a program was installed into) opens the list of everything left of it: the program itself, data, cache, preferences, containers, saved state, logs, installer receipt, cookies, login items — with sizes and check marks. What is ticked goes to the Trash. ⇧F8 and deleting several files at once take the ordinary road (no list).

### 9.14. Properties, attributes, links, tags
- **Properties** (⌘I): name, type, path, size (with folder counting), dates, permissions, owner; for folders — how many files and folders inside; for archives — the path inside the archive. Sections "Attributes" (hidden), "Permissions" (a read/write/execute grid for owner, group, everyone, the code, apply to enclosed) and "Extended attributes" with an explanation of each (quarantine, where from, tags, resource fork, encoding…) and a button to remove an attribute.
- **Change Attributes…** for several files: permissions, date modified, date created ("Now"), remove the "downloaded from the internet" quarantine.
- **Create Link**: symbolic, alias, hard (not for folders).
- **Tags** (Tools ▸ Tags, context menu): the seven Finder colours, a check mark — already set, "Remove tags".
- **Send To** — the system share sheet (AirDrop, Mail, Telegram…). SVG for Telegram is packed.
- **Open With…** — choose a program with an "Always open" checkbox (the rule changes for the whole Mac, like in Finder).
- **Reveal in Finder**, **Open in Terminal** (the external terminal is chosen in settings), **Copy file path**, **Copy folder path**.

### 9.15. Select by mask, invert, same type
See section 2.3.

---

## 10. Terminal — ⌘`

The footer button and "View ▸ Terminal". Where it opens — by setting: **ask**, **at the bottom of the window**, **in the active panel**, **in the left** or **in the right** (as a panel tab). With "ask" a menu appears, and the choice can be remembered. ⌘` again closes an open terminal. The terminal takes your shell from `$SHELL` (zsh by default) and starts in the panel's current folder. While the terminal has focus, the F-keys and the ⌃ menu shortcuts do not leak into file operations.

---

## 11. Network and Clouds

### 11.1. Connect to Server… (⇧⌘N)
The "New Connection" window in two rows of tiles:
- **Clouds — sign in through the browser**: Google Drive, Dropbox, OneDrive, Yandex Disk, Box, pCloud. Click a tile, give it a name, allow access in the browser — the cloud appears in the connection list. Another storage set up in rclone connects too.
- **Servers — address and password**: FTP, FTPS, SFTP (password or key), WebDAV, WebDAV (HTTPS), SMB, S3 (access key, secret key, bucket, region, path-style addressing for MinIO, HTTPS). Fields: name, host, port, user, password, initial path, passive mode.

The **Connection Manager** keeps saved connections: connect, edit, duplicate, delete, "connect to this server (new session)", quick connect.

### 11.2. Working on a server
A server opens in a panel tab. Everything works as with a folder: browsing, copying both ways (F5/F6 between panels), deleting, renaming, creating folders, F3 and opening files (through a temporary copy, with progress and cancel; big files ask), search. The clipboard — for local files only.

- **Edits in files from a cloud**: a file opened from a cloud in an external program is watched — after saving you are asked "Send the changes back?". Disconnecting with unsent edits offers to send them or disconnect without them.
- **Server diagnostics** on connect: file listing, whether uploads work, one or several connections.
- **Interruptions**: resuming from where it stopped, retries with a countdown, a restart of the transfer if the server cannot resume.
- **Parallel transfers** and a **speed limit** — in settings; if the server objects, the program switches to serial mode by itself.
- Google Docs/Sheets/Slides download as Office documents (Google assembles them on the fly — slower than usual) and accept edits back.
- The Google key and rclone are built into the program; nothing needs installing.

### 11.3. Local network and network drives
**Local network** — browse computers, choose a share, sign in as a guest or by name with the password remembered in the Keychain. **Connect network drive** — an address `smb://…`, `afp://…`, `nfs://…`, a list of recent ones and examples. **iCloud Drive** — a volume on the volume bar.

---

## 12. Shelf, Trash, Monitor, Disks

### 12.1. Shelf
The toolbar button and "View ▸ Shelf". Put files from different folders on it ("Put on the shelf" in the context menu), then open the shelf in a panel and take everything at once with a single F5. The "Origin" column shows the source folder. "Take off the shelf", "Clear the shelf". A folder rule can put files on the shelf too.

### 12.2. Trash
The toolbar button and "View ▸ Trash". Inside: **Restore** to the former place, **Erase permanently**, **Empty Trash** (with count and volume). Columns "Origin" and "Date deleted".

The Trash listing is flat: a folder lying in it can be entered and looked through, and ".." leads back to the Trash. The Trash gathers what was deleted anywhere: `~/.Trash`, the trash folders of other disks and the iCloud Drive trash (from there nothing can be put back, only erased). The real trash path (`~/.Trash`, and on other disks their own trash folders) opens as the Trash too, whichever way one arrives — by "..", by the path bar, from history, or at startup. **Renaming inside the Trash is not possible**: the system remembers the way back by the file's name in the Trash itself, and after a rename neither Totum Commander nor Finder could put it back.

### 12.3. System Monitor
The toolbar button and "View ▸ System Monitor" — opens in place of the list in the active panel. Tabs CPU, Memory, Energy, Disk, Network; overall figures at the top (including GPU, temperature, battery), processes below. There are 25 columns, each tab keeps its own set (right-click the header). Actions: quit, force quit, process information (path, parent, memory, kernel statistics, open files and ports), copy row, search, filter (all, mine, system, active), update frequency, row count. Other people's processes are shown without CPU and memory — the program does not ask for system rights. ⎋ closes the monitor.

### 12.4. Disk Information
Every volume with used, free and file system; a "Refresh" button.

---

## 13. The Tunnel

The strip between the panels. Everything in it is yours.

**Folders (top)** — by default like the Finder sidebar: Applications, Desktop, Documents, Downloads, Movies, Music, Pictures, plus the "Network" button. A click opens the folder in the active panel.
- **Add**: drag a folder from a panel or Finder — a line shows where it will land; or right-click "Add the active panel's folder here".
- **Right-click a folder**: change the icon (a library of 166 icons by section plus the icons of the menu commands), change the label (an empty one restores the original), move up/down, remove from the tunnel, restore the default folders.
- **Reorder**: press and drag — the button travels as a "ghost", the neighbours make way.

**Operations (bottom)** — by default Copy, Move, Delete, Folder, View, Edit. The "Move" arrow points towards the neighbouring panel.
- **Add an operation**: right-click — a submenu with every menu command by group, or the plus in the command palette (⌘P, ⌘↩). The command arrives with its icon from the menu.
- Right-click an operation: change the icon, change the label, move, remove, restore the default operations.
- Reordering — by dragging too.

**Empty tunnel space, right-click**: centre (50/50), proportions 30/70, 40/60, 60/40, 70/30, swap the panels, open the left folder in the right panel and vice versa. The border between the panels can be dragged with the mouse.

At the top of the tunnel: the **swap** button, the current percentages, the **operation queue** button. When the window is low and not every button fits, the extra folders and operations hide behind a **"More"** button with a drop-down list, and the tunnel itself never leaves its bounds. The look (width, labels, spacing, offset, whether to show the links, lines) — in the "Tunnel" settings.

---

## 14. Menu Bar

### File
New Tab ⌘T · Close Tab ⌘W · Tabs ▸ (next ⌃⇥, previous ⌃⇧⇥, rename, pin, close others, close all but pinned, colour) · Open · Open With… · Reveal in Finder · Open in Terminal · New Folder F7 · Create Text File ⇧F4 · View F3 · Edit F4 · Rename F2 · Copy to the Other Panel… F5 · Move to the Other Panel… F6 · Delete F8 · Delete, Bypassing the Trash ⇧F8 · Pack into Archive… ⌘F5 · Unpack… ⌘F9 · Archive Here ▸ · Create Link ▸ · Copy File Path · Copy Folder Path · Change Attributes… · Properties ⌘I · Connect to Server… ⇧⌘N · Close Window ⇧⌘W

### Edit
Undo ⌘Z · Redo ⇧⌘Z · Cut ⌘X · Copy ⌘C · Paste ⌘V · Select All ⌘A · Select by Mask… · Deselect by Mask… · Invert Selection · Select Files of the Same Type · Clear Selection

### View
Detailed ⌘1 · Brief ⌘2 · Thumbnails ⌘3 · Sort By ▸ · Columns ▸ · Hidden Files ⇧⌘. · Branch View: Files of All Subfolders ⌃B · Refresh ⌘R · Calculate Folder Sizes ⇧⌘↩ · Terminal ⌘` · System Monitor · Disk Information · Trash · Shelf · Operation Queue · Toggle Light/Dark Theme

### Go
Enclosing Folder ⌘↑ · Back ⌘[ · Forward ⌘] · Home ⇧⌘H · Desktop ⇧⌘D · Documents ⇧⌘O · Downloads ⌥⌘L · Applications ⇧⌘A · Pictures · Music · Movies · Root of the Disk ⇧⌘C · Favorite Folders ⌘D · Enter .app as a Folder · Follow the Link · Other Panel · Swap Panels ⌃U · Open the Left Folder in the Right Panel · Open the Right Folder in the Left Panel · Panel Proportions ▸

### Tools
Command Palette… ⌘P · Search ⌘F · Create Encrypted Vault… · Lock / Unlock Vault · Encrypt with Password (age)… · Decrypt… · Make PDF… · Merge into One PDF… · Split PDF… · Rotate Pages… · Convert Images… · Recognise Text… · Clean Photo Info… · Apply Rules to This Folder · Rules… · Multi-Rename… · Checksums… · Compare Folders… · Compare Files… · Split File… · Join Parts… · Tags ▸ · Send To ▸ · Open Disk Image the Other Way · Uninstall Program…

### Window, Help
Minimize ⌘M · Zoom · Totum Commander Help ⌘? (a window with topics: folder comparison, checksums, tags, PDF, rules, Git, file splitting, multi-rename, monitor; with text search).

Keys without ⌘ (the F-keys, ⌃B, ⌃U) act while the keyboard belongs to the file list; in the terminal and in the rename field they are not intercepted.

---

## 15. Settings (⌘,)

### General
Show hidden files · Automatic folder sizes and the load of the background calculation · Save view mode per tab · Language (system, English, Russian; changes after a restart) · Double-click interval · Confirm drag and drop · Force click on the trackpad (nothing / open / view) · Confirmation dialogs: copy/move, delete, create archive, unpack · Open terminal (ask, bottom, active, left, right) · External terminal · Opening .dmg images (as in Finder / in the panel) · Remember column widths · Breadcrumbs: select all text when editing · Claude control (a local socket for reading the panels; off until you enable it). · Window at launch: as left, a normal window or maximized (as a window, not macOS full screen) · Update check every three days: one request to GitHub, a link in About and a dot on the Settings button

### Keys
Space: quick view or select · Backspace: enclosing folder or delete · Selection: the file under the cursor takes part in operations together with the selected ones · Cmd+Q quits the program (protection from an accidental quit) · Terminal ⌘` · View and edit: in the opposite panel or as a window; native or built-in quick view; external editor.

### Terminal
Placement and the external terminal.

### List
Row height, icon scale, thumbnail size (thumbnails mode), the ".." icon (chevrons, arrow, to the top level…) and its weight, gap between name and icon, brief-mode column width, alternating rows, section separators, icon inset from the edge · Show Git marks.

### Design (colours)
Theme (system, light, dark), accent colour, panel background, interface, window title, folders and their names, files, selected files, text and background under the cursor, alternation. Every colour has its own picker (hue, saturation, brightness, eyedropper, saved colours).

### File Colours
Rules colouring names by masks, separately for the light and the dark theme, "only for recent" with fading. Order — by dragging.

### Cursor
Blur, height, width, rounding, offset and anchor, outline (colour, width), custom colour, a **custom cursor mask**: drawn with a brush or a pen, presets (gradients, bar, capsule, ellipse, slant, arrow), loading a picture. "Beauty mode" (blur and glow) is available on Apple Silicon with 14+ GPU cores.

### Folders & Icons
Folder icon style (Catalog V3…V9), images on folders from Finder, enlarging the icon under the cursor (amount, spread to neighbours).

### Font
Family, bold, size, letter spacing, enlarging the font under the cursor, preview.

### Tabs
Rounding, tab bar colour, tab colour, font, height, width and minimum width, bar height, offset, spacing, opacity and title colour of the active tab.

### Tunnel
Width, gap between links and operations, spacing between icons, vertical offset, show the folder links, labels under the icons, line opacity and thickness.

### Context Menu
**Your own menu** — the context menu for files and folders is built by hand. On the left, every program command (a hundred and fifty of them — the same ones the menu bar and the ⌘P palette hold) with a search field: **＋** puts a command into the menu, the **down arrow** puts it under the "More" button. On the right, two lists: **Menu** — what is seen at once, and **Under "More"** — what appears after pressing it. In every row the arrows change the order, the sideways arrow moves an item between the parts, **✕** takes it out of the menu for good. Everything can be taken out, down to the last item. **Separator** is one more entry in the left-hand list and can be placed as many times as wanted. **Defaults** brings back the menu the program came with.

An item still shows only when it applies to the file: "Extract" for an archive, "Follow the link" for a link. A program command that is unavailable at that moment does not disappear — it goes grey. Pressing "More" adds the rest straight into the open menu: it neither closes nor is built again, and the rows already read stay where they were. The menu on empty space is short and is not built here. Below — font size, icon size, padding, highlight rounding, minimum width, with a live preview of the real menu.

### Network & NTFS
Concurrent operations, speed limit, remote operations straight to the queue, the administrator password for writing to NTFS (save to Keychain / remove).

### About
Version and build, developer, repository, build branch.

---

## 16. Key Summary

| Key | Action |
|---|---|
| F1 | Help (where F1 is taken by brightness — fn+F1 or ⇧⌘?) |
| F2 / F3 / F4 | Rename / View / Edit |
| F5 / F6 / F7 / F8 | Copy / Move / Folder / Delete |
| ⇧F8, ⇧⌦ | Delete, bypassing the Trash |
| F9, ⌘F | Search |
| F10 / F11 / F12 | Sound: mute / quieter / louder |
| ⌘F5 / ⌘F9 | Pack / Unpack |
| ↩ / ⇧↩ | Open / open a disk image the other way |
| ⇧⌘↩ | Calculate folder sizes |
| ⌫ | Enclosing folder (or delete, by setting) |
| ⌘↑ / ⌘[ / ⌘] | Enclosing folder / Back / Forward |
| ⇧ + two-finger swipe | Left — enclosing folder; right — back down the same trail, one folder per swipe, to where the climb began; with no trail, forward in the history or into the folder under the cursor |
| ⇥ | Other panel |
| Space | Quick view or select (by setting) |
| ⌘A, Num +, Num −, Num * | Select all, by mask, deselect by mask, invert |
| ⌘C / ⌘X / ⌘V | File clipboard |
| ⌘Z / ⇧⌘Z | Undo / redo an operation |
| ⌘R | Refresh |
| ⇧⌘. | Hidden files |
| ⌃B | Branch view |
| ⌘1 / ⌘2 / ⌘3 | Detailed / Brief / Thumbnails |
| ⌘T / ⌘W / ⌃⇥ / ⌃⇧⇥ | Tabs: new, close, next, previous |
| ⌘D | Favorite folders |
| ⌘I | Properties |
| ⌘P | Command palette (there ⌘↩ — to the tunnel) |
| ⌘` | Terminal |
| ⌃U | Swap panels |
| ⇧⌘N | Connect to server |
| ⌘, | Settings |
| ⌘? | Help |
| ⎋ | Clear selection, close the filter, view, monitor, palette; interrupt the branch read |
| Any letter or digit | Quick filter |

The **Fn** button in the footer toggles the F-key mode: with it F1–F12 reach the program without the fn key. If some F-keys are captured by another program (often Parallels — F6), you are told.

The mode switches the whole keyboard at once — it cannot be set per key — and F10–F12 stop being sound keys. The program does their work itself: **F10** mutes, **F11** turns it down, **F12** turns it up, in the same steps macOS uses. No system volume badge appears. It does not matter who put the keyboard in that mode — the **Fn** button or your own macOS setting: once the key reaches the program, it no longer controls the sound, so the program does it instead.

If F11 shuffles windows off the screen instead of changing the volume, and F10 shows the program's windows, macOS has taken those keys for Mission Control and they never reach any program. The easiest way to see and fix this is in the program itself: **Settings ▸ Keys ▸ “Sound keys”** — the section says whether macOS is holding one of the keys and frees it with a single button. The same by hand: **System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control**, uncheck “Show Desktop” (F11); the shortcut can be switched back on there. In a new user account it is on by default.

**F1** opens this manual. On some keyboards plain F1 is taken by the system for screen brightness and never reaches any program — then **fn+F1** and **⇧⌘?** do it.

---

## 17. Control from Claude (MCP)

With the setting "Allow Claude to see the panels" enabled the program opens a local socket for this Mac only and only while it runs. Through it the assistant sees what the panels show, reads folder listings, searches files, checks the leftovers of programs; copying, moving, creating a folder and sending to the Trash happen only after your permission in the program's dialog. Until you enable it — off.

---

## 18. Where to Find Help Inside the Program

- **⌘?** — the help window with topics and text search.
- The **"How it works"** buttons in the folder comparison, checksums, splitting, multi-rename, rules and PDF windows.
- The **"?"** sign at the quick filter — how to write a mask.
- Tooltips on the toolbar, footer and tunnel buttons.

If you did not find an answer, caught a bug, or want something the program does not do yet, write: **pixmap1981@gmail.com**. The address is also in Settings ▸ About.
