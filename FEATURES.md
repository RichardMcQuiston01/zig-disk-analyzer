# Features

[Back to README](./README.md)

| [Two Views](#two-views) | [Live Scanning](#live-scanning) | [Moving Around](#moving-around) | [Right-Click Menu](#right-click-menu) | [Deleting Items](#deleting-items) | [How Sizes Are Counted](#how-sizes-are-counted) | [Drives](#drives) |

## Two Views

The app shows the current folder in two ways at once.

**List view (left).**
Each row shows a name and a size, sorted from largest to smallest.
A thin bar under the name shows how much of the folder that item uses.
Folders have a blue folder icon, and files have a gray page icon.
Names that are too long end with `...`.

**Treemap view (right).**
Each item is a tile, and the tile's area matches its size.
Folders get a color based on their name, so a folder keeps its color while the scan runs.
Files are gray.
Big tiles show the name and size.
Hover over any tile to see its name and size in a small box.

[Back to Top](#features)

## Live Scanning

The scan runs in the background, so the window stays quick to use.
Each file and folder shows up as soon as the scan finds it.
Folder sizes grow as their contents are counted.
The views refresh four times a second while the scan runs.

The line under the path at the top shows the progress:

- `Scanning...` with the number of items and the total size so far.
- `Done` with the final numbers when the scan finishes.

You can click into a folder before the scan is done and watch it fill in.

[Back to Top](#features)

## Moving Around

- Click a folder's row or tile to open it.
- Click **Up** to go back one level.
- Click any folder name in the path at the top to jump back to it.
- Click **Rescan** to scan the same drive again.
- Click **Change Drive** to go back to the drive list.

[Back to Top](#features)

## Right-Click Menu

Right-click any row in the list or any tile in the treemap.
The menu shows the item's name at the top, then these choices:

| Choice | Shown for | What it does |
|---|---|---|
| **Open Folder** | Folders | Opens the folder in File Explorer. |
| **Open Containing Folder** | Files | Opens the file's folder in File Explorer, with the file selected. |
| **Delete (to Recycle Bin)** | Both | Asks you to confirm, then moves the item to the Recycle Bin. |

While a scan is running, Delete is grayed out and reads **Delete (after the scan finishes)**.
On Linux and macOS, it reads **Delete (Windows only)**.

To close the menu, press Esc or click anywhere else.

[Back to Top](#features)

## Deleting Items

Delete always asks first.
The confirm box shows the item's name, type, size, and full path.
Click **Move to Recycle Bin** to go ahead, or **Cancel** to stop.

After you confirm:

1. The app moves the item to the Recycle Bin in the background. Windows may show its own progress window.
2. If the item cannot go to the Recycle Bin, Windows asks before deleting it for good. For example, it may be too large, or the drive may not have a Recycle Bin.
3. When the item is gone, it leaves both views. Its size is taken off every folder above it, so you do not need to rescan.
4. A message at the bottom of the window says what happened.

Space is only freed when you empty the Recycle Bin.
The `$Recycle.Bin` folder in the views does not grow until you rescan.

If only part of a folder could be moved, the app says so and asks you to rescan.
This can happen when files are in use or protected by Windows.
The app does not guess the new sizes.

[Back to Top](#features)

## How Sizes Are Counted

- A file's size is its real length in bytes. A folder's size is the total of everything inside it.
- Shortcuts to other folders, called links or junctions, are not followed. This stops loops and double counting. For example, `Documents and Settings` on drive C shows as `0 B`.
- Folders you do not have permission to open count as empty.
- Windows keeps some system files locked, like `pagefile.sys`, `hiberfil.sys`, and `swapfile.sys`. The app still finds their real size, because these files are often the largest on the drive.

[Back to Top](#features)

## Drives

- On Windows, the app lists every drive letter from `A:\` to `Z:\` that it can open.
- On Linux, it lists `/` plus any folders under `/media` and `/mnt`.
- On macOS, it also lists the folders under `/Volumes`.

[Back to Top](#features)

---

[Back to README](./README.md)
