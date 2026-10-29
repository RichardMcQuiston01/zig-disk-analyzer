# Troubleshooting

[Back to README](./README.md)

| [Build Fails While the App Is Open](#build-fails-while-the-app-is-open) | [Errors From raylib-zig](#errors-from-raylib-zig) | [raylib Will Not Link on Windows](#raylib-will-not-link-on-windows) | [Linux Cannot Find raylib](#linux-cannot-find-raylib) | [Names Show Question Marks](#names-show-question-marks) | [Delete Is Grayed Out](#delete-is-grayed-out) | [Delete Did Not Finish](#delete-did-not-finish) |

## Build Fails While the App Is Open

Windows locks a program while it runs.
If the app is open, `zig build` cannot replace `zig-out\bin\diskviz.exe`, and the build fails.

Close the app, then build again.

[Back to Top](#troubleshooting)

## Errors From raylib-zig

You may see errors like `member function expected 2 argument(s), found 1` or `no field named 'root' in struct 'Build'`.
These come from the `raylib-zig` package. Its current build script needs a newer Zig than 0.16.

This project does not use `raylib-zig`. If you added it:

1. Remove the `raylib_zig` entry from `build.zig.zon`.
2. Delete the `zig-pkg` folder.
3. Build again with `zig build`.

[Back to Top](#troubleshooting)

## raylib Will Not Link on Windows

This happens when `-Draylib_path` points at the Microsoft Visual C++ (MSVC) build of raylib.
That build does not link with the default `x86_64-windows-gnu` target.

Use the copy in `vendor/raylib` by leaving out `-Draylib_path`.
Or download the MinGW-w64 build of raylib and point `-Draylib_path` at it.

[Back to Top](#troubleshooting)

## Linux Cannot Find raylib

If the build says it cannot find `raylib`, pass the folder of the raylib Linux release:

```sh
zig build -Draylib_path=/path/to/raylib-5.5_linux_amd64
```

Ubuntu 24.04 has no `libraylib-dev` package, so you need the release download.
See [Getting Started](./GETTING_STARTED.md#linux).

If the build says it cannot find `GL` or `X11`, install the development packages:

```sh
sudo apt install libgl-dev libx11-dev
```

[Back to Top](#troubleshooting)

## Names Show Question Marks

The app can show English, accented, Greek, and Cyrillic letters.
Other scripts, like Chinese, Japanese, or Korean, show as `?`.
Emoji also show as `?`.

If every letter beyond basic English shows as `?`, the font file was not found.
Open **Settings** to check. It says `Font file not found - using the built-in font` in that case.
See [Configuration](./CONFIGURATION.md#font).

[Back to Top](#troubleshooting)

## Delete Is Grayed Out

- **Delete (after the scan finishes)**: wait for the status line to say `Done`. Delete is off during a scan, because the scan might still be adding to that part of the tree.
- **Delete (Windows only)**: the Recycle Bin feature only works on Windows for now.

[Back to Top](#troubleshooting)

## Delete Did Not Finish

The message at the bottom of the window gives the reason. Common ones:

| Message | What to do |
|---|---|
| Access denied | The item may be a protected system file, or it may need administrator rights. |
| A file is in use by another program | Close the program using the file, then try again. |
| The item no longer exists | It was moved or deleted after the scan. Click **Rescan**. |
| Some items couldn't be moved | Part of the folder was moved. Click **Rescan** to see what is left. |
| Nothing was deleted | You said no when Windows asked about deleting for good. Nothing changed. |

[Back to Top](#troubleshooting)

---

[Back to README](./README.md)
