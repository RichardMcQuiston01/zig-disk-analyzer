# Disk Usage Analyzer (Zig + raylib)

A small desktop tool that scans a drive and shows where the space went, two ways
at once:

- **List view** (left) — every file/folder in the current directory with its
  size, sorted largest-first, with a proportional bar.
- **Treemap view** (right) — a squarified 2D map where each node's area is
  proportional to its size on disk.

Pick a drive, and the list and treemap fill in **live** as the background scan
walks the tree. Click any folder (in either view) to drill in; use the
breadcrumb or **↑ Up** to go back.

## Requirements

- **Zig 0.16.0 or 0.17.0** (both verified). The code uses the `std.Io`
  filesystem API, so Zig 0.15 and earlier won't work.
- **raylib** — vendored for Windows; a system install on Linux/macOS.

## Build & run

### Windows

No downloads or flags. A prebuilt raylib 5.5 (official MinGW-w64 release) is
vendored in `vendor/raylib`, and the build defaults to the matching GNU ABI.

```sh
zig build run -Doptimize=ReleaseFast
```

Output: `zig-out\bin\diskviz.exe`. It's a single self-contained executable
(raylib is linked statically). Release builds run as a pure GUI app; Debug
builds keep a console window open so panics and logs stay visible.

### Linux / macOS

Install raylib, then build:

```sh
# Debian/Ubuntu:  sudo apt install libraylib-dev
# macOS:          brew install raylib
zig build run -Doptimize=ReleaseFast
```

### Using a different raylib

Point the build at any prebuilt raylib (the folder containing `lib/` and
`include/`):

```sh
zig build run -Draylib_path="C:\path\to\raylib"
```

On Windows, use a **MinGW-w64** build of raylib: the default target is the GNU
ABI, which won't link against an MSVC `raylib.lib`.

> **Why not build raylib from source?** The `raylib-zig` package tracks Zig
> nightly, and its build script fails on stable Zig 0.16 and 0.17. Linking a
> prebuilt raylib through the app's own C-ABI bindings (`src/raylib.zig`)
> avoids depending on it entirely.

## Controls

| Action | How |
|---|---|
| Choose a drive | Click a drive on the start screen |
| Drill into a folder | Click its row (list) or tile (treemap) |
| Go up one level | **↑ Up**, or click a breadcrumb segment |
| Scroll the list | Mouse wheel over the list |
| Rescan current drive | **Rescan** |
| Pick a different drive | **Change Drive** |
| Change font or text size | **Settings** (on the start screen and the top bar). Close with **Done**, Esc, or a click outside |
| Open, reveal, or delete an item | **Right-click** its row or tile (see below) |

## Right-click menu

Right-click any row in the list or tile in the treemap:

- **Open Folder** (folders): opens it in Explorer.
- **Open Containing Folder** (files): opens the parent folder in Explorer with
  the file selected.
- **Delete (to Recycle Bin)**: asks for confirmation (showing the name, size,
  and full path), then moves the item to the Recycle Bin.
  - It runs in the background, so the window stays responsive. Windows may show
    its own progress window.
  - If an item can't be recycled (too large for the Recycle Bin, or a drive
    without one), **Windows asks before deleting anything permanently**.
  - When the item is confirmed gone, it's removed from the view and its size
    is subtracted from every folder above it, with no rescan needed. Space is
    actually freed when the Recycle Bin is emptied.
  - If only part of a folder could be moved (files in use, protected files),
    the app says so and suggests a rescan rather than guessing at the new
    sizes.
  - Delete is unavailable while a scan is running, because the scanner may
    still be adding to that part of the tree.
- Close the menu with Esc or by clicking anywhere else.

On Linux and macOS, the two Open actions use the system's default file manager.
Delete is Windows-only for now.

## Settings

- **Font**: Arial, Times New Roman, or Courier (Courier New on Windows). Fonts
  load from `C:\Windows\Fonts`. On Linux the metric-compatible Liberation fonts
  are used, then DejaVu; on macOS, the system copies. If a font file can't be
  found, the app falls back to raylib's built-in font and the Settings dialog
  says so.
- **Text size**: Smaller (80%), Normal (100%), or Larger (120%). This scales
  all text and the layout around it (row heights, padding, icons, buttons).
- File names with accented letters, Greek, or Cyrillic render correctly with
  any of the three fonts. Other scripts (e.g. Chinese, Japanese) need a font
  that includes them, and still show as `?`.
- Choices are saved to `diskviz.ini` next to the executable
  (`zig-out\bin\diskviz.ini`) and restored on the next start.

## How scanning works

- Scanning runs on a **background thread**, and the UI stays at 60 FPS.
- Results are **live**. Each file and folder appears as soon as it's found, and
  its size is added to every folder above it at the same moment. You can drill
  into a folder mid-scan and watch it fill in. The view re-reads the tree 4
  times a second while scanning, then once more when the scan finishes.
- The UI reads the tree only through a snapshot that captures children and
  their sizes together under the scan lock. The totals you see always add up,
  even while the scan is still writing.
- **Symlinks and junctions are not followed** (they count as negligible size).
  This avoids cycles and double-counting.
- Sizes are **apparent file sizes** (the sum of `stat` sizes), not on-disk block
  allocation. Directories you can't read (permissions) count as empty.
- On Windows, files the OS holds open exclusively (`pagefile.sys`,
  `hiberfil.sys`, `swapfile.sys`) can't be opened to read their size. Their
  size is read from directory metadata instead, so these often-huge files
  aren't shown as 0 B.

## Project layout

| Path | Responsibility |
|---|---|
| `src/main.zig` | Window and render loop, allocator and `Io` setup |
| `src/ui.zig` | Drive picker, list view, treemap view, settings dialog, navigation, input |
| `src/typography.zig` | Font loading (per exact pixel size, so text stays sharp), size scaling, fit-to-width with "..." |
| `src/settings.zig` | Font/size choices and the `diskviz.ini` format |
| `src/shell.zig` | Open folder, reveal file, and move to Recycle Bin (Win32 shell APIs) |
| `src/scanner.zig` | Threaded recursive scanner: arena-owned `Node` tree, atomics, cancellation |
| `src/model.zig` | `Node` tree type, sorting, size fractions |
| `src/treemap.zig` | Squarified treemap layout (pure geometry) |
| `src/drives.zig` | Cross-platform drive/volume enumeration |
| `src/format.zig` | Human-readable byte/percent formatting |
| `src/raylib.zig` | Thin raylib C-ABI binding (only the functions the app uses) |
| `vendor/raylib/` | raylib 5.5 static lib and header for Windows (zlib license) |

## Tests

The pure logic and the threaded scanner are unit-tested. No GUI or display is
needed:

```sh
zig build test
```

The tests cover byte formatting, the squarified layout (area proportionality and
containment), node sorting, end-to-end scans of known temp trees (including
totals sampled mid-scan), the settings file format, and UTF-8-safe text
truncation.
