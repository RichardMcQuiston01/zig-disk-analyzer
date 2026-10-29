# Tech Stack

[Back to README](./README.md)

| [Tools and Libraries](#tools-and-libraries) | [Project Layout](#project-layout) | [Design Notes](#design-notes) |

## Tools and Libraries

| Tool | Version | Used for |
|---|---|---|
| [Zig](https://ziglang.org/) | 0.16.0 or 0.17.0 | The language and the build system |
| [raylib](https://www.raylib.com/) | 5.5 | The window, drawing, fonts, and input |
| Windows shell functions | Built into Windows | Opening File Explorer and using the Recycle Bin |

The raylib copy in `vendor/raylib` uses the zlib license. Its terms are in `vendor/raylib/LICENSE`.

[Back to Top](#tech-stack)

## Project Layout

| Path | What it holds |
|---|---|
| `build.zig` | Build steps, raylib linking, and the test list |
| `build.zig.zon` | Package name, version, and minimum Zig version |
| `src/main.zig` | Opens the window and runs the main loop |
| `src/ui.zig` | The drive list, both views, the menus, the dialogs, and input |
| `src/scanner.zig` | The background scan and the tree of files and folders |
| `src/model.zig` | The `Node` type that stores one file or folder |
| `src/treemap.zig` | The math that lays out the treemap tiles |
| `src/drives.zig` | Finds the drives you can scan |
| `src/format.zig` | Turns byte counts into labels like `1.4 GB` |
| `src/settings.zig` | The font and size choices and the settings file format |
| `src/typography.zig` | Loads fonts, scales text, and cuts long names short |
| `src/shell.zig` | Opens folders, shows files, and moves items to the Recycle Bin |
| `src/raylib.zig` | The app's own small link to raylib's C functions |
| `vendor/raylib/` | raylib 5.5 for Windows, ready to link |

[Back to Top](#tech-stack)

## Design Notes

**Why the app has its own raylib link.**
The popular `raylib-zig` package follows the newest Zig.
Its current build script fails on Zig 0.16.
So the app talks to raylib's C functions directly, through `src/raylib.zig`.
raylib's C functions rarely change, so this works on both Zig 0.16 and 0.17.
On Windows, it also means nothing has to be downloaded during the build.

**How the scan stays safe while you browse.**
The scan runs on its own thread.
Each change to the tree happens under a lock, and each folder's total is updated in the same step.
The views read a snapshot of names and sizes taken under the same lock.
So the totals you see always add up, even while the scan is still running.

**Why text stays sharp.**
raylib draws each font at one pixel size.
Stretching that to other sizes looks blurry.
So the app loads each font at every exact size it uses, and keeps those copies ready.

[Back to Top](#tech-stack)

---

[Back to README](./README.md)
