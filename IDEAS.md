# Ideas

Planned quality-of-life improvements, with implementation notes.

## Status

- [x] Settings menu: **Font** and **Font size**. Done; see "Settings" in
  the README. The notes below are kept for reference.
- [ ] Settings menu: **Visualization method** (Circles, Spheres)
- [x] Right-click context menu. Done; see "Right-click menu" in the README.
  Not yet done: Delete during a scan, and Delete on Linux/macOS (trash).

## Settings menu

A **Settings** button in the top bar opens a panel. Choices persist between
runs in a small config file next to the executable (`diskviz.ini`).

### Font

Choose between **Arial**, **Times New Roman**, and **Courier**.

- Load with raylib `LoadFontEx` from `C:\Windows\Fonts` (`arial.ttf`,
  `times.ttf`, `cour.ttf`). Fall back to raylib's built-in font if a file is
  missing.
- Load the Latin-1/Latin Extended code points along with ASCII. This also fixes
  file names with accented or non-English characters, which currently render as
  `?` because the built-in font is ASCII-only.
- Switch text drawing from `DrawText`/`MeasureText` to `DrawTextEx`/
  `MeasureTextEx` so every draw call uses the selected font.
- Non-Windows: pick equivalents (DejaVu Sans / Serif / Mono, or the macOS system
  fonts), or let the user set a font path.

### Font size

**Smaller (80%) / Normal (100%) / Larger (120%)**

- **Normal** is the current set of sizes, unchanged. **Smaller** is 20% smaller
  and **Larger** is 20% larger.
- Implement as one scale factor (0.8 / 1.0 / 1.2) applied to every font size in
  the UI, rounded to whole pixels. For example, list text goes 16px → 13 / 16 /
  19px; status text goes 14px → 11 / 14 / 17px.
- Row height, header height, icon size, and the minimum tile size for showing a
  label should scale by the same factor, so the layout stays proportional.

### Visualization method

**Squares** (current squarified treemap) / **Circles** / **Spheres**

- **Circles**: circle packing, where each circle's *area* is proportional to the
  size. Use a front-chain packing algorithm (as in d3's `packSiblings`), then
  scale the packed group to fit the panel. Circles leave empty space, so the
  view shows less detail per pixel than squares; that's the trade-off for the
  look.
- **Spheres**: same layout as Circles, drawn with shading. Draw each circle as a
  radial gradient (`DrawCircleGradient`) with the light center offset toward
  the top-left, plus a small specular highlight. A 2.5D look with no 3D
  rendering.
- Keep layout and drawing behind one interface (`layout(sizes, area) -> shapes`,
  `draw(shape)`) so hit-testing, tooltips, and click-to-drill-in work the same
  in every mode.

## Right-click context menu

A small popup at the cursor on right-click, in both the list and the treemap.

| Item | Shown for | Windows implementation |
|---|---|---|
| **Open Folder** | Folders | `ShellExecuteW(null, "open", path, ...)` opens it in Explorer |
| **Open Containing Folder** | Files | `explorer.exe /select,"<path>"` opens the parent with the file highlighted (or `SHOpenFolderAndSelectItems`) |
| **Delete (Send to Recycle Bin)** | Both | `SHFileOperationW` with `FO_DELETE` + `FOF_ALLOWUNDO` (or `IFileOperation` with `FOFX_RECYCLEONDELETE`) |

Notes:

- **Full paths**: build from the node's parent chain (`buildPathAlloc` in
  `scanner.zig` already does this).
- **Delete confirmation**: always confirm first, showing the name and size.
  Deleting from a disk-usage tool is easy to do by accident.
- **Delete while scanning**: either disable Delete until the scan finishes, or
  have the scanner thread apply the removal under its lock so the tree stays
  consistent.
- **After a delete**: remove the node from its parent and subtract its size from
  every ancestor (the reverse of `publish`), so the view updates without a
  rescan.
- **Failures**: files in use, permission errors, and protected system files
  will fail. Show the OS error message in a small notice, and leave the tree
  unchanged.
- **Non-Windows**: `xdg-open` / `open` for opening; `gio trash` or the
  freedesktop trash spec on Linux, and Finder's move-to-trash on macOS.
