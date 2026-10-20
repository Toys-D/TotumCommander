# Totum Commander — Complete Guide

Totum Commander is a two-panel file manager for macOS in the spirit of Total Commander. Everything below was gathered from the program itself: its menus, keys, buttons, context menus and settings. Keys use the macOS notation: ⌘ Command, ⇧ Shift, ⌥ Option, ⌃ Control, ↩ Return, ⌫ Backspace, ⇥ Tab, ⎋ Esc. If the program is new to you, start with "First Five Minutes" below.

---

## First Five Minutes

Two panels side by side, and nearly everything is done with keys, as in Total Commander. One panel is always active: the cursor lives there, and keys and menu commands apply to it. This is enough to start working right away.

| What to do | How |
|---|---|
| Switch to the other panel | ⇥ or a click on it |
| Enter a folder, open a file | ↩ or a double-click |
| Go one level up | ⌫, ⌘↑ or the ".." row |
| Back and forward in history | ⌘[ and ⌘] |
| Select files | ⌘-click one by one, ⇧+arrows for a run, ⌘A for all |
| Copy or move to the other panel | F5 or F6; with nothing selected, the file under the cursor is taken |
| Rename, new folder, delete to the Trash | F2, F7, F8 |
| Look at a file, edit text | Space — quick view, F3 — viewer, F4 — editor |
| Find a file in the open folder | Start typing its name — the list narrows to the matches |
| Find a file anywhere | F9 or ⌘F |
| Undo a mistake | ⌘Z undoes a copy, move, rename or delete |
| Open another folder alongside | ⌘T — a new tab, ⌘W — close it |
| Find any command | ⌘P — the command palette: type what you want to do |
| Make it yours | ⌘, — settings; ⌘F there finds a setting |

**F-keys on a Mac.** The top row of a Mac keyboard controls brightness and sound by default, and F5 without fn never reaches the program. Press **Fn** in the bottom bar of the window and the F-keys work without fn (details in section 15).

From here on the guide goes section by section. ⇧⌘? and F1 always open it, and the help window has a text search.

---

## 1. The Window

The window has five parts.

| Part | What it is |
|---|---|
| **Two panels** | A file list on the left and on the right. One panel is always active: the cursor lives there, and keys and menu commands apply to it. Switch with ⇥ or a click. |
| **Tunnel** | The narrow strip between the panels: quick links to folders at the top, operation buttons at the bottom. Fully customisable (section 13). |
| **Toolbar** | The top of the window: Shelf, Trash, system monitor, disk information, theme, hidden files, settings (a red dot on the button — a new version is out, section 14). In "Settings ▸ General ▸ Toolbar" the buttons can be shown with labels or as labels alone, and the groups set apart by a line. |
| **Footer** | Bottom of the window: F2…F9 as buttons, the Fn-mode switch and the terminal button. |
| **Menu bar** | File, Edit, View, Go, Tools, Window, Help. The menu holds **every** command of the program, and it feeds the command palette and the tunnel. The full list is in the appendix at the end of this guide. |

Above each list, top to bottom: the volume bar (disks), breadcrumbs (path), tabs, the sort header. Below the list — the status bar: how many files, how many selected, how much free space.

After a change of screen resolution the window opens centred, not in a corner.

---

## 2. The Panel: File List

### 2.1. View modes (View menu, ⌘1 / ⌘2 / ⌘3, buttons on the volume bar)

| Mode | What it shows |
|---|---|
| **Detailed** ⌘1 | A table with columns. Columns are enabled in "View ▸ Columns" or by right-clicking the header: type, size, date modified, date created, date added, permissions, owner, "From" (on the Shelf and in the Trash). Column widths are dragged with the mouse; the header menu offers "Reset column widths" and "Auto-fit all columns". Widths are remembered (setting). |
| **Brief** ⌘2 | Names only, in several columns. Column width is set in the "List view" settings. |
| **Thumbnails** ⌘3 | Picture thumbnails and icons. The tile size is set in the "List view" settings. |

The mode can be remembered per tab ("Remember view mode" in the tab menu) or saved for every tab automatically (setting "Save view mode per tab").

### 2.2. Sorting

Click a column header to sort, click again to reverse. The same lives in "View ▸ Sort By": name, extension, type, size, date modified, date created, date added, owner, permissions; a separate "Descending" toggle.

The default sorting (field and direction) is set in the "List view" settings. There too lives "Remember sorting in every folder": on — a folder opens with the sorting you set in it, and a folder without one with the default; off — a click on a column lasts only until you move to another folder.

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

**Select by mask** (Edit ▸ Select by Mask… / Unselect by Mask…): `*` — any characters, `?` — one. Several masks: `*.png&*.pdf` (or via `|`, `,`, `;`). Exclude: `!copy*`. The dialog remembers recent masks.

### 2.4. Navigation

| Action | How |
|---|---|
| Open a folder, archive, file | ↩ or double-click. A file opens in its default program; a .app is launched. |
| Enclosing folder | ⌫ (by default; a setting can turn ⌫ into delete), ⌘↑, the ".." row. |
| Back / Forward in history | ⌘[ and ⌘] |
| Other panel | ⇥ |
| Home, Desktop, Documents, Downloads, Applications, Pictures, Music, Movies, Root of the disk | The "Go" menu (⇧⌘H, ⇧⌘D, ⇧⌘O, ⌥⌘L, ⇧⌘A, ⇧⌘C) or the quick links in the tunnel. |
| Favorite folders | ⌘D — the list of favourite folders. Add and remove the current one there and in the context menu. |
| Browse .app as a folder | Context menu or "Go". |
| Follow Symlink | For a symbolic link — into the target's folder, cursor on the target. |
| Breadcrumbs | Click a segment to go there. Right-click: edit the path, copy the path, paste a path and go. Setting "Select all text when editing path". |
| Refresh | ⌘R |

**Branch view** (⌃B, View ▸ Branch) — the files of every subfolder as one list, as in Total Commander. While the tree is being read a counter sits at the bottom; ⎋ interrupts. ⌃B again returns the ordinary folder.

**Hidden files** — ⇧⌘. or the toolbar button.

**Folder sizes** — ⇧⌘↩ calculates the size of every folder in the current folder. Automatic calculation is enabled in settings; the load of the background calculation (10…100 % of cores) can be limited. On slow external disks (USB 2, network) the program switches to an economy mode by itself: folder sizes are not calculated, metadata is loaded on demand.

### 2.5. Quick filter

Start typing in the panel — a filter bubble opens and the list narrows. The mask is the same as for selection: `*`, `?`, several masks separated by space/`&`/`|`, `!` to exclude, no asterisk — a fragment of the name (`png|pdf`). By Finder tags: `#red` (the beginning is enough: `#re`), `#` — any tag, `!#re` — without it.

Bubble buttons: **Select** what is shown, **Deselect**, **Invert**, **Delete** what is shown (with the usual confirmation). A mask can be **remembered** and picked from a list later. ⎋ closes the filter and restores the folder; ⌫ edits the text; arrows, ↩ and the F-keys keep working on the narrowed list.

### 2.6. What else the list shows

- **Finder tags** — coloured dots after the name. Set with the right button (Tools ▸ Tags), visible in Finder too.
- **Git state** — a letter before the name (M, A, D, R, ?, !, ·) and the branch name on a repository folder with an orange "uncommitted changes" dot. Enabled in the "List view" settings. Details in the "Git state" topic of the help window (⇧⌘?).
- **Colours by file type** — names are coloured by the rules in "Settings ▸ File colours": a mask (`*.dmg;*.pkg`), a colour for the light and the dark theme, "Recent files only" with gradual fading.
- **Pictures on folders** — icons assigned to folders in Finder (setting "Show custom folder pictures").
- **Folder icon styles** — "Catalog V3…V9" and "Totum" (the app's own folder: the body takes the folder colour, the outline and the white "TC" stay) in the "Folders & icons" settings, and your own: the "Custom…" tile takes an SVG or a PNG. The style is remembered separately for the light and the dark theme.
- **New-items counter** — "+12" after the name of a folder where files appeared or were overwritten; in thumbnails, a plaque in the corner of the picture. Enabled in the "File colours" settings (section 14).

### 2.7. Volume bar

Left to right: every mounted disk, the clouds you are signed in to through their own apps (iCloud Drive, Google Drive, OneDrive, Dropbox, Box, pCloud, Yandex Disk — with their logos), the network button. Click a disk to go to its root. The **⏏** button ejects a disk; if the disk is busy in other programs or in the program itself (operations running, unsaved files) you are told and offered a forced eject. On a cloud the same button disconnects nothing: it moves the button from the bar into the network menu, where one click brings it back. Right-click — **Disk information**: interface, file system, total, free. From the disk's interface the program picks its working mode (full speed for internal SSDs and Thunderbolt, economy for USB and network).

The network button opens a menu: **Local network** (browse computers and shares), **Connect network drive** (smb://, afp://, nfs://), **FTP disk** (the connection manager: servers and clouds through rclone, section 11.1), and below them the clouds that are not in the bar right now; each one says what a click will do: bring it back to the bar, **sign in** (the app is installed but nobody is signed in), **install** (no app) or **turn on in System Settings** (iCloud Drive is off). Details in section 11.4.

---

## 3. Tabs

Each panel has its own tabs. The "File ▸ Tabs" menu and the right button on a tab:

| Action | How |
|---|---|
| New tab | ⌘T, "+" on the tab bar |
| New terminal | In the tab menu, by right-clicking "+" or with ⌘T inside a terminal (section 10). |
| Close | ⌘W, the cross. Pinned tabs do not close. |
| Next / previous | ⌃⇥ / ⌃⇧⇥ |
| Pin / unpin | A pinned tab does not close and is narrower. A terminal tab cannot be pinned. |
| Rename | Your own title instead of the folder name. |
| Colour | Red, orange, yellow, green, blue, purple, graphite, custom, none. |
| Close others | "Close Other Tabs" and "Close All Except Pinned" — in the tab menu. |
| Remember / forget view mode | The tab remembers detailed/brief/thumbnails. |
| Reorder | By dragging. |

Tabs come in four kinds: a folder, a **terminal** (section 10), a **remote connection** — a server or a cloud (section 11) — and a **network volume** mounted through macOS (section 11.3, orange icon). Clicking a local disk from a server or network-volume tab does not turn it into an ordinary one: the disk opens in the nearest local tab (or a new one), the server stays connected, and clicking it in the volume bar returns to its tab. The active tab stands above the others, so you can see at once which one is open. The look of tabs (height, width, rounding, font, lift, opacity and title colour of the active tab) — in the "Tabs" settings.

---

## 4. File Operations

### 4.1. The basics (F-keys, footer, tunnel, "File" menu)

| Key | Operation | Details |
|---|---|---|
| F2 | Rename | Right in the list. ↩ confirms, ⎋ cancels. A name with `/` is refused. If another file already has the name, you can replace it (the old one is deleted) or take a numbered name, “hair (1).svg”; with a folder — only the numbered name. Changing just the case (`hair` → `Hair`) works. While a copy is running, F2 sends it to the queue. |
| F3 | View | Section 6. |
| F4 | Edit | Section 7. |
| F5 | Copy to the other panel | A dialog with the destination folder (any path can be typed), a "To queue (F2)" button and a "Don’t show this dialog again" checkbox. |
| F6 | Move to the other panel | The same. |
| F7 | New folder | The name is asked; not inside an archive. |
| ⇧F4 | Create text file | As in Total Commander: the name is asked, the file is made and opened in the editor at once; an existing name simply opens. |
| F8 | Delete | To the Trash, with confirmation (configurable). A single .app opens the **program uninstaller** instead (section 9.13). |
| ⇧F8, ⇧Delete | Delete, bypassing the Trash | Permanently, with a separate warning. |
| ⌦ (Forward Delete) | Delete | Like F8; with ⇧ — bypassing the Trash. |
| ⌫ | Enclosing folder **or** delete | By the setting "Backspace — navigate to parent folder". |
| F9, ⌘F | Search | Section 8. |
| ⌘F5 | Pack into an archive | Section 5. |
| ⌘F9 | Unpack | Section 5. |
| ⌘I | Properties | Section 9.14. |

Operations on several files take the selection; without a selection — the file under the cursor. The setting "Keys ▸ Selection" adds the file under the cursor to the selection (handy after ⇧+arrows, when the cursor already stands on the next row). The ".." row never takes part.

### 4.2. Name conflicts

If the file already exists at the destination you are asked: **Replace**, **Replace all**, **Create copy** (with a "(copy)", "(copy 2)"… suffix), **Skip**, **Skip all**, **Cancel**. The size and date of both files are shown with a hint which one is newer and larger. Copying into the same folder offers to create duplicates.

### 4.3. Clipboard

⌘C copies files to the clipboard, ⌘X cuts (the paste becomes a move), ⌘V pastes into the current folder. Works with Finder in both directions. The clipboard does not work with servers and clouds — use F5/F6 there. ⎋ abandons a pending cut.

### 4.4. Undo — ⌘Z and ⇧⌘Z

Move, copy, rename, delete to the Trash and create can be undone. The "Edit ▸ Undo" item names what will come back. If something is in the way (the file has already moved, the name is taken, the folder is no longer empty) you are told, and the undo can be repeated after the cause is removed. In a text field ⌘Z still undoes typing.

### 4.5. Operation queue

The button with circling arrows in the tunnel (the number of operations is inside the icon) and "View ▸ Operation Queue". Every operation has its own progress and **Pause / Resume / Cancel / Dismiss** buttons; completed ones are cleared in one go. An interrupted network transfer can **continue from where it stopped**. Below the operations in the tunnel, mini progress bars are drawn.

Settings: **concurrent operations** (how many the queue runs at once), **speed limit** for network transfers, **remote operations straight to the queue**. The progress window asks for confirmation when cancelling (can be turned off with "Don't ask next time"). A system notification arrives when done.

### 4.6. Drag and drop

- What you drop into a panel — from the other panel, from Finder or from another program — is copied; with ⇧ or ⌘ held it is moved. Dropped onto a folder row, it goes into that folder.
- A drop takes the same road as F5 and F6: the same window with the destination folder opens. "Confirm copy/move" in "Settings ▸ General ▸ Confirmation dialogs" turns it off.
- From a panel into Finder and other programs it is always a copy.
- Entries dragged out of an archive are unpacked where they are dropped.
- A folder dropped into the tunnel lands where it was released (section 13).

### 4.7. NTFS disks

macOS does not write to NTFS; the program can: on the first write it asks for the administrator password. It can be saved in the Keychain ("Network & NTFS" settings), after which it is not asked again. For the time of the write the disk is temporarily remounted. Archives cannot be modified directly on NTFS — copy them to a local disk.

---

## 5. Archives

An archive opens with ↩ like an ordinary folder; inside you can browse, view and edit files (edits are offered to be written back), and copy out. A nested archive inside an archive is read-only.

**Formats**: ZIP, TAR, TAR.GZ, 7Z, TAR.BZ2, TAR.XZ, TAR.ZST, TAR.LZ, TAR.LZ4, ISO, DMG; read-only — RAR and PKG installer packages.

**Pack** (⌘F5, context menu): name and destination folder, archiver, compression level, preserve paths, include subfolders, delete source files after packing, separate archives for every file, **password (AES-256)** — for ZIP the contents are encrypted and the names stay visible; for DMG everything is encrypted. The progress shows the compression ratio and the estimated result.

**Archive here** — a submenu with formats: the archive lands next to the files, no questions.

**Unpack** (⌘F9, context menu): destination folder, "Create subfolder with archive name", "Overwrite existing files". A password-protected archive asks for it; the password is kept in memory until the program quits. An encrypted ZIP without the right password is not unpacked at all — it is refused, and no empty files are left behind; a cancelled unpack removes the half-written file.

**Editing an archive** — adding, deleting and renaming inside ZIP and other formats. If the format needs a full repack, you are warned with the archive size. Only ordinary local files can be added to an archive.

The pack and unpack dialogs can be turned off in the "Confirmation dialogs" settings.

**Installer packages (.pkg)**: ↩ enters a package like an archive: the Distribution file, the installer resources and the component packages. Inside a component, Payload holds what the package installs and Scripts the install scripts; both can be entered, a pbzx Payload as in Apple's packages too. Packages are read-only. ⇧↩ starts the installer, as a double-click in Finder does.

**Disk images (.dmg, .cdr, .toast)**: by setting they open "as in Finder" (the installation window) or "in the panel" (mounted, and the panel goes inside). ⇧↩ always opens the other way; the same command is "Tools ▸ Open Disk Image the Other Way". An `.iso` file is judged by its contents: a real ISO opens as an archive, without mounting, while a DMG under an `.iso` name (programs are often handed out that way) takes the disk-image road.

---

## 6. View (F3) and Quick View (Space)

**F3** opens the viewer for the file under the cursor (a folder opens too — its contents are shown). With the setting "Viewer (F3) in the opposite panel" it is embedded in the neighbouring panel, otherwise it opens as a window. **Space** — quick view: native Apple Quick Look or the built-in one "with modes" (setting). ⎋ and Space close the view.

**Modes** (switch at the top, "How to show this file"): Auto, Quick Look, Image, Text, HEX, PDF, Document, Video, Info, Font, Drawing, Book, Model.

| What | Particulars |
|---|---|
| Images | Zoom and pan with the trackpad. The **Read the text** button highlights the lines found, "Copy all". The **photo info** panel: size, camera, lens, shutter, aperture, ISO, date, place (open in Maps, copy coordinates), a "Remove metadata…" button. The **Origin** section — for a picture made by a neural network: what made it (Stable Diffusion, ComfyUI, Midjourney, NovelAI, ChatGPT, Firefly…), the prompt, the negative prompt, the model and settings, C2PA content credentials. Such a picture shows itself without that section too: a "Made by a neural network" badge with a "Remove metadata…" button in the viewer's header, and a "Made by a neural network — remove metadata…" item in the context menu. What is shown is what the file says; an invisible watermark in the pixels themselves (Google's SynthID) cannot be seen this way. |
| PDF, DjVu | A page strip (show/hide), paging. |
| Documents | Word, Excel, Pages, Numbers and the rest — through the system engine. |
| Text | Encoding choice, big files are truncated for viewing, binaries suggest HEX. Markdown is shown formatted: headings, lists, quotes, code blocks. |
| Video and audio | Built-in player. |
| Fonts | TTF, OTF, TTC — a glyph table. |
| Drawings | DXF (text variant). |
| 3D models | OBJ, STL, PLY, USD/USDZ, DAE, SCN are read by macOS itself; glTF/GLB, FBX, 3DS, Blender, 3MF, STEP and dozens more — by the built-in library. Rotate and zoom with the mouse, "Show the wireframe", "Put the camera back", the number of meshes, vertices and faces. |
| PostScript | Through Ghostscript. |
| Books | FB2 and EPUB: contents, notes, ← → and PgUp/PgDn turn pages, bookmarks (add, remove, rename, list), "Count this page as the first" for numbering without the cover. |

The "File N of M" line — the viewer pages through the folder's files. Files from a cloud are downloaded to a temporary copy first; a big file asks whether to download.

---

## 7. Editor (F4)

The built-in editor runs on Monaco (the VS Code engine): language highlighting, several files in tabs, go to line ⌘L. ⌘S saves, ⌘W closes the tab; closing with edits asks once. The editor recognises the file's encoding itself — UTF-8, Windows-1251 or Latin-1 — and saves in the same one. A file that cannot be read as text opens read-only. A file from an archive offers to be written back after ⌘S.

**The editor toolbar** has icons with captions: font, font size, theme, "Find", "Replace", "Wrap", "Invisibles", "Minimap", "Highlight" and the language; what is on stands on an accent-coloured backing. The header, bars and status line take the colours of the text theme: dark for the dark theme, light for the light one. In the editor window word wrap, invisible characters and the minimap also toggle with ⇧⌘W, ⇧⌘I, ⇧⌘M.

**Find and replace** — a bar above the text: ⌘F or "Find", together with the replace field — ⌘R or "Replace". A selection on one line becomes the search text at once. Every match is highlighted and the counter shows "3 of 8"; the "Previous" and "Next" buttons, ↩ and ⇧↩ in the field, ⌘G and ⇧⌘G walk through them. "Replace" changes the current match and moves to the next, "Replace All" changes them all at once, and ⌘Z brings them back in one step. Toggles "Match case", "Whole word", "Regex"; $1, $2 work in a regular-expression replacement. ⎋ closes the bar, not the editor.

RTF opens in its own editor: bold, italic, underline.

With the setting "Editor (F4) in the opposite panel" the editor is embedded in the neighbouring panel. The "Editor" field in "Settings ▸ General" replaces the built-in editor with any application.

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

### 9.2. Compare folders…
The folder of the left panel against the folder of the right, with all subfolders. Filter "Differences / All", a mask, an exclusion mask (`.DS_Store;*.tmp`), "Compare by content", "Ignore date". Every file has an arrow — what will happen to it: → and ← copy, move (with a little bin), to the Trash, leave alone; clicking the row cycles the options, the right button picks one directly. A summary of the plan at the bottom; the **Synchronize** button shows the total and only after confirmation does anything. Deletions always go to the Trash. Detailed help — in the window ("How it works") and in ⇧⌘?.

### 9.3. Compare Files…
Two files (two selected in one panel or under the cursor in each panel) line by line: differences highlighted, "Only differences", line wrap, ⌥↓ / ⌥↑ — next and previous difference. Binary files are compared byte by byte.

### 9.4. Checksums…
MD5, SHA-1, SHA-256 for the selected files in one pass. Copy one or all, save to a file in md5sum/shasum format, the **Verify** field: paste a sum from a website — "Matches" or "Does not match" by any of the three algorithms.

### 9.5. Split file… / Join parts…
Cuts a file into parts of a given size (10 MB, 25 MB, 100 MB, CD, DVD or your own), names them `name.001, .002…` like Total Commander and HJSplit, puts them into the other panel's folder, optionally writes a `.sha256`. Joining finds the other parts by itself, verifies the sum and can move the parts to the Trash — only if the sum matched.

### 9.6. Multi-Rename…
Name and extension masks with tags: `[N]` name, `[N2-5]` a part, `[E]` extension, `[C]` counter (start, step, digits, letters), `[Y][M][D][h][m][s]` date and time, `[P][G][B0]` folder names, `[=tc.size]`, `[=tc.width]` metadata, `[U][L][F][f][n]` case, `[X]` clipboard. Find and replace (regex, case, first only, in extension), case of the result, `/` in the mask sorts into folders. A preview with conflict highlighting, editing a name by double-click, **Undo**, presets. The tag reference — a button in the window.

### 9.7. Rules… / Apply Rules to This Folder
A rule: conditions (name by mask, extension, kind of file, size, age by date modified/created/added, tag) and an action (move, copy, rename by mask, to the Trash, set a tag, to the Shelf, unpack), with "Where to" and a subfolder by date (`yyyy/MM`). Rules are read top to bottom; a file takes the first that matches. Applying happens only on command over the current folder, with a "what will happen" list and a switch on every row. Everything can be undone with ⌘Z.

### 9.8. PDF
**Make a PDF…** from pictures (page by picture size or A4 with margins, order with arrows), **Merge into one PDF…** (two or more), **Split the PDF…** (every page, every N pages, chosen ranges `1-3, 7, 12-`), **Rotate the pages…** (90° right/left, 180°, all or a range, copy or replace the original). The result lands next to the first file with a mark in the name; existing files are never overwritten.

### 9.9. Convert the images…
Format (JPEG, PNG, HEIC, TIFF or keep), quality, keep photo info, size (fit into a side, fraction of the original, allow upscaling), where (next to the original with a suffix, into a subfolder, replace the original). At the bottom — the plan for every file.

### 9.10. Read the text…
The macOS system recogniser, no internet: pictures, scans, PDF (page by page, honouring the document's own text layer). The text can be selected, copied whole or saved as `.txt` next to the file.

### 9.11. Remove metadata…
Takes the hidden notes out of files — who made them, with what, when and where. Nothing is recompressed: the notes are cut out of the file, and the picture, the sound and the text stay byte for byte.
- **Pictures** (JPEG, HEIC, PNG, TIFF, GIF, WebP): EXIF, XMP, IPTC, the place, the camera, comments, and for pictures made by neural networks — the prompt, the settings and the C2PA content credentials. The orientation and the colour profile stay — a portrait will not lie on its side.
- **Film and sound** (MOV, MP4, M4A, WAV, AIFF): where it was shot, the camera, the program, tags; the file is put together anew from its own tracks. **MP3, FLAC** — tags and cover art.
- **Documents**: PDF — properties, XMP, the notes inside embedded photographs, the authors of comments (links and form fields are left alone; a password-protected PDF is not rewritten). Word, Excel, PowerPoint, OpenDocument — author, company, template, dates, custom properties.
- **Any file** — the macOS notes: where it was downloaded from, tags, the Finder comment. The "downloaded from the internet" mark stays: macOS checks the file by it before the first opening.

Either everything or only the place (GPS) — the latter touches only photographs and films. A copy marked "(cleaned)" or overwriting the original (irreversible). The command is in the context menu (the tools submenu) and in the Tools menu; it appears only when the file has something to say about itself.

### 9.12. Encryption
- **New Encrypted Vault…** — a safe-file with a size ceiling (space is taken as it fills), a password and optionally Touch ID. ↩ opens it as a folder, "Lock the vault" turns it back into a file. "Ask for the password, forget Touch ID" and "Open with Touch ID" — in the context menu.
- **Encrypt with a password (age)…** / **Decrypt…** — `.age` envelope files. The originals stay after encryption; delete them yourself. ↩ on an `.age` offers to decrypt.

### 9.13. Uninstall the program…
The command "Tools ▸ Uninstall the program…" or F8 on a single `.app` (or the folder a program was installed into) opens the list of everything left of it: the program itself, data, cache, preferences, containers, saved state, logs, installer receipt, cookies, login items — with sizes and check marks. What is ticked goes to the Trash. ⇧F8 and deleting several files at once take the ordinary road (no list).

### 9.14. Properties, attributes, links, tags
- **Properties** (⌘I): name, type, path, size (with folder counting), dates, permissions, owner; for folders — how many files and folders inside; for archives — the path inside the archive. Sections "Attributes" (hidden), "Permissions" (a read/write/execute grid for owner, group, everyone, the code, apply to enclosed) and "Extended attributes" with an explanation of each (quarantine, where from, tags, resource fork, encoding…) and a button to remove an attribute. A folder also gets "Folder picture", as in Finder: choose a picture, paste it from the clipboard or drop it onto the icon, or remove it — it applies at once, and Finder and other apps see it too. A picture assigned here is shown in the panels even when it looks like an ordinary folder; if showing pictures on folders was off, it is turned on.
- **Change Attributes…** for several files: permissions, date modified, date created ("Now"), remove the "downloaded from the internet" quarantine.
- **Create Link**: symbolic, alias, hard (not for folders).
- **Tags** (Tools ▸ Tags, context menu): the seven Finder colours, a check mark — already set, "Clear tags".
- **Send to** — the system share sheet (AirDrop, Mail, Telegram…). SVG for Telegram is packed.
- **Open With…** — choose a program with an "Always open this way" checkbox (the rule changes for the whole Mac, like in Finder).
- **Show in Finder**, **Open in Terminal** (the external terminal is chosen in settings), **Copy file path**, **Copy path**.


---

## 10. Terminal — ⌘`

The footer button and "View ▸ Terminal". Where it opens — by setting: **ask**, **at the bottom of the window**, **in the active panel**, **in the left** or **in the right** (as a panel tab). With "ask" a menu appears, and the choice can be remembered. ⌘` again and the terminal button, by the setting in "Settings ▸ Terminal", either **hide** the terminal — what runs in it keeps running, and the next press brings it back exactly as it was — or **close** it and stop everything running in it. The terminal takes your shell from the $SHELL variable (zsh by default) and starts in the panel's current folder. While the terminal has focus, the F-keys and the ⌃ menu shortcuts do not leak into file operations.

**Several terminals.** As many terminal tabs as you like, in either panel: "New terminal" in the tab menu, a right-click on "+" in the tab bar, or ⌘T inside a terminal.

**Splitting into parts.** Any terminal, the bottom one too, can be split: ⌘D side by side, ⇧⌘D one above the other. Any part can be split again; the borders are dragged with the mouse. ⌥⌘ with the arrows moves to the neighbouring part; ⌘W or `exit` closes a part. A new part opens in the folder its neighbour's shell is in. The keys work while the cursor is in the terminal, in any keyboard layout. There is no need to memorise them: above every part sits a slim strip with "split" and "close" buttons, and a right-click opens a menu (copy, paste, split, new terminal, close) that shows the keys next to each item.

A file dropped into the terminal is typed into the line as its path, and the keyboard goes to the terminal at once; dropped from Finder, it also brings the window forward.

---

## 11. Network and Clouds

### 11.1. Connect to Server… (⇧⌘N)
The "New Connection" window in two rows of tiles:
- **Clouds — sign in with a browser**: Google Drive, Dropbox, OneDrive, Yandex Disk, Box, pCloud. Click a tile, give it a name, allow access in the browser — the cloud appears in the connection list. Another storage set up in rclone connects too.
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
**Local network** — browse computers, choose a share, sign in as a guest or by name with the password remembered in the Keychain. **Connect network drive** — an address `smb://…`, `afp://…`, `nfs://…`, a list of recent ones and examples. The mounted volume opens in its own tab with an orange icon and stays there while you walk the local disks (section 3). What is put into the open folder on the server itself, the panel shows by itself: macOS passes on the server's notifications, and if the server sends none, the panel checks with it every few seconds.

### 11.4. Clouds through their own apps
Google Drive, OneDrive, Dropbox, Box, pCloud and Yandex Disk can be connected without rclone — through the vendors' own apps. A cloud you are signed in to in such an app (the folders macOS keeps in Library/CloudStorage, a pCloud volume, a Yandex Disk folder in your home) takes its place in the volume bar by itself, as an ordinary place: no API quotas and no second sign-in; iCloud Drive works the same way. The eject button on such a cloud only moves it from the bar into the network menu, where one click brings it back.

In the network menu every cloud says what a click will do. **Sign in** — the vendor's app is installed but nobody is signed in: the app is launched. **Install** — for Google Drive, OneDrive, Dropbox and Box the program downloads the installer from the vendor's official address into Downloads, shows the progress, checks the developer signature and selects the file in Finder; running the installer and signing in is up to you; a file without a signature or with someone else's is deleted, and you are told. pCloud and Yandex Disk open their download pages. **Turn on in System Settings** — iCloud Drive is off: System Settings open.

---

## 12. Shelf, Trash, Monitor, Disks

### 12.1. Shelf
The toolbar button and "View ▸ Shelf". Put files from different folders on it ("Put on the shelf" in the context menu), then open the shelf in a panel and take everything at once with a single F5. The "From" column shows the source folder. "Take off the shelf", "Empty the shelf". With the setting "the file under the cursor takes part in operations" it goes on the shelf too. A folder rule can put files on the shelf too.

### 12.2. Trash
The toolbar button and "View ▸ Trash". Inside: **Put Back** to the former place, **Erase forever**, **Empty Trash** (with count and volume). Columns "From" and "Date Deleted".

The Trash listing is flat: a folder lying in it can be entered and looked through, and ".." leads back to the Trash. The Trash gathers what was deleted anywhere: `~/.Trash`, the trash folders of other disks and the iCloud Drive trash (from there nothing can be put back, only erased). The real trash path (`~/.Trash`, and on other disks their own trash folders) opens as the Trash too, whichever way one arrives — by "..", by the path bar, from history, or at startup. **Renaming inside the Trash is not possible**: the system remembers the way back by the file's name in the Trash itself, and after a rename neither Totum Commander nor Finder could put it back.

### 12.3. System monitor
The toolbar button and "View ▸ System monitor" — opens in place of the list in the active panel. Tabs CPU, Memory, Energy, Disk, Network; overall figures at the top (including GPU, temperature, battery), processes below. Columns are chosen by right-clicking the header; each tab keeps its own set. Actions: quit, force quit, process information (path, parent, memory, kernel statistics, open files and ports), copy row, search, filter (all, mine, system, active), update frequency, row count. Other people's processes are shown without CPU and memory — the program does not ask for system rights. ⎋ closes the monitor.

### 12.4. Disk information
Every volume with used, free and file system; a "Refresh" button.

---

## 13. The Tunnel

The strip between the panels. Everything in it is yours.

**Folders (top)** — by default like the Finder sidebar: Applications, Desktop, Documents, Downloads, Movies, Music, Pictures, plus the "Network" button. A click opens the folder in the active panel.
- **Add**: drag a folder from a panel or Finder — a line shows where it will land; or right-click "Add the active panel's folder here".
- **Right-click a folder**: change the icon (a library of icons by section plus the icons of the menu commands), change the label (an empty one restores the original), move up/down, remove from the tunnel, restore the default folders.
- **Reorder**: press and drag — the button travels as a "ghost", the neighbours make way.

**Operations (bottom)** — by default Copy, Move, Delete, Folder, View, Edit. The "Move" arrow points towards the neighbouring panel.
- **Add an operation**: right-click — a submenu with every menu command by group, or the plus in the command palette (⌘P, ⌘↩). The command arrives with its icon from the menu.
- Right-click an operation: change the icon, change the label, move, remove, restore the default operations.
- Reordering — by dragging too.

**Empty tunnel space, right-click**: centre (50/50), proportions 30/70, 40/60, 60/40, 70/30, swap the panels, open the left folder in the right panel and vice versa. The border between the panels can be dragged with the mouse.

At the top of the tunnel: the **swap** button, the current percentages, the **operation queue** button. When the window is low and not every button fits, the extra folders and operations hide behind a **"More"** button with a drop-down list, and the tunnel itself never leaves its bounds. The look (width, labels and their font size, spacing, offset, whether to show the links) — in the "Center Divider" settings.

---

## 14. Settings (⌘,)

A search field at the top of the sidebar (⌘F puts the cursor there): while you type, the page is replaced by the list of matching settings with their sections, and sections without matches dim. Clicking a result opens the section, scrolls to the setting and outlines it for a moment. Case and "ё" do not matter; every word you type has to occur.

The colours of the interface, cursor and tabs, the file-colour rules and the folder style are remembered separately for the light and the dark theme: you edit the theme that is on screen right now.

### General
- **Language** — system, English or Russian; it changes after a restart.
- **Show hidden files** — the same as ⇧⌘. and the toolbar button.
- **Auto-calculate folder sizes** — subfolder sizes are computed by themselves. **Background calculation load** — from 10 % (a couple of quiet threads, sizes appear gradually) to 100 % (all cores). A manual recount with ⇧⌘↩ always runs at full speed.
- **Save view mode per tab** — every tab remembers detailed, brief or thumbnails.
- **Remember column widths across sessions.**
- **Opening disk images (.dmg)** — as in Finder (the installation window) or in the panel (the volume is mounted and the panel goes inside). ⇧↩ always opens the other way.
- **Toolbar** — buttons as icons only, icons with labels or labels only; separators between the buttons.
- **At launch** — the window as it was last time, a normal window or maximized (as a window, not macOS full screen).
- **Editor** — an external application for F4; with the field empty, the built-in editor works.
- **Mouse** — double-click interval; force click on the trackpad: nothing, open or view.
- **Confirmation dialogs** — whether to ask before copying and moving (drag and drop too), deleting, creating an archive, unpacking.
- **Breadcrumbs** — select all text when editing the path.
- **Updates** — check at launch and every three days: one request to GitHub with nothing about you. When a new version is out, a red "Update to …" button appears in About and a red dot on the Settings button.

### Keys
- **Space key** — quick view (the default) or selecting the file, like Insert in Total Commander. **Quick view** — native Apple Quick Look or the built-in one, with modes.
- **View and edit** — F3 and F4 open in the opposite panel or in a window of their own.
- **Backspace** — go to the parent folder (the default) or delete, like Delete.
- **Selection** — the file under the cursor takes part in operations together with the selected ones. Off — as in Total Commander: if anything is selected, operations take only the selection.
- **Sound keys** — tells whether macOS holds one of F10–F12 with its own shortcut, and frees it with one button (section 15).
- **Cmd+Q** — whether ⌘Q quits the program; switch it off so as not to quit by accident.

### Terminal
- **Open terminal in** — ask, the bottom of the window, the active, left or right panel.
- **⌘` and terminal button** — hide the terminal (what runs in it keeps running) or close and stop it.
- **Reverse scrolling** — the terminal scrolls the same way as everything else on the system; the switch is for a mouse or trackpad that still makes it go the other way.
- **External terminal** — what opens "Open in Terminal"; only installed terminals are listed.
- **Keys** — ⌘D and ⇧⌘D split the terminal, ⌥⌘ with the arrows moves to the neighbouring part, ⌘W closes a part, ⌘T opens a new terminal in a tab (section 10).

### List view
- **Sorting** — the default field and direction; "Remember sorting in every folder" (section 2.2).
- **Git state** — show Git marks in the list (section 2.6).
- **List rows** — brief-mode column width, row height, icon scale, gap between name and icon, icon inset from the edge (in detailed and brief modes), gap between columns (between brief-mode columns and between thumbnails).
- **Thumbnails mode** — tile size.
- **The ".." icon** — kind (chevrons, arrow, to the top level…), scale and weight.

### Design
- **Theme** — system, light or dark.
- **App accent** — the accent colour and the colour under the cursor; colours of folder icons, folder and file names, selected files; alternating rows and their colour; grid lines — vertical, horizontal, their colour and opacity; panel background, interface colour, window title. Every colour has its own picker: hue, saturation, brightness, eyedropper, saved colours.
- **About this Mac** — processor, memory, graphics and whether beauty mode is available: it needs Apple Silicon with a GPU of 14 cores or more.
- **Beauty mode** — blur, glow and other interface effects.
- **Smooth animation** — the icon and font under the cursor do not jump to the new size but grow into it; at launch the rows slide into place like a staircase.
- **Cursor effects** — height, width, corner rounding, blur, offset and anchor on X and Y.
- **Custom cursor (mask)** — the "Draw…" button: white is the body of the cursor, black is transparency. Brush, pen, eraser, "Invert", "Clear"; presets — horizontal and vertical gradients, edges, bar, capsule, ellipse, slant, arrow; a picture of your own — "Load…" or dragged straight onto the canvas.

### File colours
- **Rules** — names are coloured by masks (`*.dmg;*.pkg`): a colour for the light and for the dark theme, "Recent files only" with gradual fading. The order of the rules — by dragging. Recent means it appeared in the folder or was overwritten within the rule's period. In system folders (/System, /Library, /usr and the other system roots), in ~/Library, in cache folders and in hidden ones nothing is marked new at all — neither by colour nor by the counter: programs rewrite their files there all the time.
- **Mark folders with something new inside** — after the name of a folder where files appeared or were overwritten within the period of the "any name" rule, at any depth, stands a counter, "+12": that many new files inside. It takes the colour of the folder's name — under the cursor, of the name under the cursor — and fades towards the end of the period. In thumbnails the counter is a plaque in the corner of the picture. A dropped file shows up at once, even one brought in through Finder while the app was in the background: what is new comes from the disk's change log, older things from Spotlight; the disk is not walked. Network and hidden folders get no counter.

### Cursor
- **Custom cursor color** — the cursor background and the colour of the text under it. Off — the cursor takes the app accent, and the name under it is picked to contrast.
- **Outline the cursor** — colour and width: a crisp rim around the blurred body.

The shape, blur and mask of the cursor live in "Design", in the "Effects" group.

### Folders & icons
- **Icon style** — Catalog V3…V9, Totum or your own. It is chosen for the theme on screen right now (the title names it) and remembered separately for light and dark.
- **Show custom folder pictures** — pictures assigned to folders in Finder or in "Properties" (⌘I).
- **Icon under cursor** — enlarge it, the amount, the neighbour reach.

**Your own folder style.** The "Custom…" tile takes an SVG or a PNG and checks it strictly: what breaks the rules is not taken, and the refusal says what to fix. An SVG recolours to the folder colour like the built-in styles: a square canvas (viewBox), filled shapes only, colour roles — `#FF00FF` folder colour, `#B000B0` darker, `#FFFFFF` white, `#000000` shadow (may be translucent); no text (convert it to outlines), images, links, scripts, hidden layers, gradients, masks or filters; styles only as plain classes (`.st0 { fill: #FF00FF; }`), the way Illustrator writes them; up to 200 KB. "Sample SVG…" saves a ready folder drawn to these rules — redraw it as you like. A PNG is a square of 512 to 2048 px on a transparent background, up to 2 MB: it is recoloured by lightness (its main tone becomes the folder colour) or, with "Recolour to the folder colour" off, kept as it is. The picture is copied to the app — the original can be deleted. To remove a style of yours — the cross on hover or a right-click.

### Font
- **List font** — family, bold, size, letter spacing, preview.
- **Font under cursor** — whether to enlarge it and by how much. Neighbouring rows grow part of the way; how far it carries is set by "Neighbour reach" in "Folders & icons".

### Tabs
- Tab font, rounding, tab height, width and minimum width, tab bar height, spacing between tabs.
- **Active tab lift** — how many points the active tab stands above the others (0 keeps them level). If the raised tab does not fit, the tab bar grows.
- **Active tab** — fill opacity and title colour. The fill is the app accent from "Design".

### Center Divider
- Divider width, gap between links and operations, spacing between icons (up to 20 px), vertical offset.
- Show the folder links; labels under the icons and their font size. Labels fit once the divider is wide enough.

### Context Menu
**Your own menu** — the context menu for files and folders is built by hand. On the left, every program command (the same ones the menu bar and the ⌘P palette hold) with a search field: **＋** puts a command into the menu, the **down arrow** puts it under the "More" button. On the right, two lists: **Menu** — what is seen at once, and **Under the "More" button** — what appears after pressing it. In every row the arrows change the order, the sideways arrow moves an item between the parts, **✕** takes it out of the menu for good. Everything can be taken out, down to the last item. **Separator** is one more entry in the left-hand list and can be placed as many times as wanted. **Defaults** brings back the menu the program came with.

An item still shows only when it applies to the file: "Unpack" for an archive, "Follow Symlink" for a link. A program command that is unavailable at that moment does not disappear — it goes grey. Pressing "More" adds the rest straight into the open menu: it neither closes nor is built again, and the rows already read stay where they were. The menu on empty space is short and is not built here. Below — font size, icon size, padding, highlight rounding, minimum width, with a live preview of the real menu.

### Network & NTFS
- **Simultaneous operations** — how many operations the queue runs at once: network transfers and local copies alike. If a server refuses an extra connection, the program switches to serial mode by itself.
- **Speed limit** — a ceiling for network transfers so a big upload does not take the whole line; it applies from the next file.
- **Send remote operations directly to queue** — transfers with servers go straight into the operation queue (section 4.5) and run in the background.
- **NTFS writing** — the administrator password can be saved in the Keychain, after which the program stops asking for it on every write; "Remove password" deletes it.

### About
Version and build, developer, company, licence, repository, contact, an "All releases on GitHub" button. **Updates**: "Check", "You have the latest version" or a red **"Update to …"** button — the image is downloaded from GitHub, verified against the published checksum, put in place of the previous version, and the program relaunches; a program running straight from the image or from a temporary copy is first asked to be moved to Applications. Below — a word on supporting the project through PayPal; nothing in the program depends on it.

---

## 15. Key Summary

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
| ⌘T / ⌘D / ⇧⌘D / ⌥⌘←↑↓→ / ⌘W | In the terminal: new terminal, split side by side, one above the other, to the neighbouring part, close the part |
| ⌃U | Swap panels |
| ⇧⌘N | Connect to server |
| ⌘, | Settings |
| ⇧⌘? | Help |
| ⎋ | Clear selection, close the filter, view, monitor, palette; interrupt the branch read |
| Any letter or digit | Quick filter |

The **Fn** button in the footer toggles the F-key mode: with it F1–F12 reach the program without the fn key. If some F-keys are captured by another program (often Parallels — F6), you are told.

The mode switches the whole keyboard at once — it cannot be set per key — and F10–F12 stop being sound keys. The program does their work itself: **F10** mutes, **F11** turns it down, **F12** turns it up, in the same steps macOS uses. No system volume badge appears. It does not matter who put the keyboard in that mode — the **Fn** button or your own macOS setting: once the key reaches the program, it no longer controls the sound, so the program does it instead.

If F11 shuffles windows off the screen instead of changing the volume, and F10 shows the program's windows, macOS has taken those keys for Mission Control and they never reach any program. The easiest way to see and fix this is in the program itself: **Settings ▸ Keys ▸ “Sound keys”** — the section says whether macOS is holding one of the keys and frees it with a single button. The same by hand: **System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control**, uncheck “Show Desktop” (F11); the shortcut can be switched back on there. In a new user account it is on by default.

**F1** opens this manual. On some keyboards plain F1 is taken by the system for screen brightness and never reaches any program — then **fn+F1** and **⇧⌘?** do it.

---

## 16. Where to Find Help Inside the Program

- **⇧⌘?** — the help window with topics and text search.
- The **"How it works"** buttons in the folder comparison, checksums, splitting, multi-rename, rules and PDF windows.
- The **"?"** sign at the quick filter — how to write a mask.
- Tooltips on the toolbar, footer and tunnel buttons.

If you did not find an answer, caught a bug, or want something the program does not do yet, write: **pixmap1981@gmail.com**. The address is also in Settings ▸ About.

---

## Appendix. Menu Bar

Every command of the program by menu, with its keys. The same commands can be found in the ⌘P palette and placed as buttons in the tunnel.

### Totum Commander
About Totum Commander · Settings… ⌘, · Hide Totum Commander ⌘H · Hide Others ⌥⌘H · Show All · Quit Totum Commander ⌘Q (in "Settings ▸ Keys" ⌘Q can be switched off so the program is not closed by accident)

### File
New Tab ⌘T · Close tab ⌘W · Tabs ▸ (next ⌃⇥, previous ⌃⇧⇥, rename, pin, close others, close all but pinned, colour) · Open · Open With… · Show in Finder · Open in Terminal · Create folder F7 · Create text file ⇧F4 · View F3 · Edit F4 · Rename F2 · Copy to the Other Panel… F5 · Move to the Other Panel… F6 · Delete F8 · Delete, Bypassing the Trash ⇧F8 · Pack to archive… ⌘F5 · Unpack… ⌘F9 · Archive Here ▸ · Create Link ▸ · Copy file path · Copy path · Change Attributes… · Properties ⌘I · Connect to Server… ⇧⌘N · Close Window ⇧⌘W

### Edit
Undo ⌘Z · Redo ⇧⌘Z · Cut ⌘X · Copy ⌘C · Paste ⌘V · Select All ⌘A · Select by Mask… · Unselect by Mask… · Invert Selection · Select Files of the Same Type · Clear Selection

### View
Detailed ⌘1 · Brief ⌘2 · Thumbnails ⌘3 · Sort By ▸ · Columns ▸ · Hidden Files ⇧⌘. · Branch View: Files of All Subfolders ⌃B · Refresh ⌘R · Calculate Folder Sizes ⇧⌘↩ · Terminal ⌘` · System monitor · Disk information · Trash · Shelf · Operation Queue · Toggle light / dark theme

### Go
Enclosing Folder ⌘↑ · Back ⌘[ · Forward ⌘] · Home ⇧⌘H · Desktop ⇧⌘D · Documents ⇧⌘O · Downloads ⌥⌘L · Applications ⇧⌘A · Pictures · Music · Movies · Root of the Disk ⇧⌘C · Favorite Folders ⌘D · Browse .app as a folder · Follow Symlink · Other Panel · Swap Panels ⌃U · Open Left Folder in Right Panel · Open Right Folder in Left Panel · Panel Proportions ▸

### Tools
Command palette… ⌘P · F9 Search ⌘F · New Encrypted Vault… · Lock / Unlock Vault · Encrypt with a password (age)… · Decrypt… · Make a PDF… · Merge into one PDF… · Split the PDF… · Rotate the pages… · Convert the images… · Read the text… · Remove metadata… · Apply Rules to This Folder · Rules… · Multi-Rename… · Checksums… · Compare folders… · Compare Files… · Split file… · Join parts… · Tags ▸ · Send to ▸ · Open Disk Image the Other Way · Uninstall the program…

### Window, Help
Minimize ⌘M · Zoom · Totum Commander Help ⇧⌘? (a window with topics: folder comparison, checksums, tags, PDF, rules, Git, file splitting, multi-rename, monitor; with text search).

Keys without ⌘ (the F-keys, ⌃B, ⌃U) act while the keyboard belongs to the file list; in the terminal and in the rename field they are not intercepted.
