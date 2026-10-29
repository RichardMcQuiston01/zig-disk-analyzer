# Getting Started

[Back to README](./README.md)

| [Requirements](#requirements) | [Windows](#windows) | [Linux](#linux) | [macOS](#macos) | [Build Options](#build-options) | [Running the Tests](#running-the-tests) |

## Requirements

- Zig 0.16.0 or 0.17.0. Both are tested. Check your version with `zig version`.
- Older versions of Zig will not work. The code uses the newer file system interface added in 0.16.
- raylib 5.5. How you get it depends on your system. See the steps below.

[Back to Top](#getting-started)

## Windows

The repo comes with a copy of raylib 5.5 in `vendor/raylib`.
It is the official MinGW-w64 build, and it is linked into the app.
You do not need to download anything else.

1. Clone the repo:

   ```sh
   git clone https://github.com/RichardMcQuiston01/zig-disk-analyzer.git
   cd zig-disk-analyzer
   ```

2. Build and start the app:

   ```sh
   zig build run -Doptimize=ReleaseFast
   ```

The app is saved as `zig-out\bin\diskviz.exe`.
It is one file. You can copy it anywhere and run it.

On Windows, the build uses the `x86_64-windows-gnu` target by default.
That target matches the raylib copy in the repo, so you do not need to pass `-Dtarget`.

[Back to Top](#getting-started)

## Linux

These steps were tested on Ubuntu 24.04.
Ubuntu does not have a raylib package, so you use the official raylib release instead.

1. Install the development packages for OpenGL (graphics) and X11 (the X Window System, which draws windows on Linux):

   ```sh
   sudo apt install libgl-dev libx11-dev
   ```

2. Download `raylib-5.5_linux_amd64.tar.gz` from the [raylib 5.5 release page](https://github.com/raysan5/raylib/releases/tag/5.5), then unpack it:

   ```sh
   tar xzf raylib-5.5_linux_amd64.tar.gz
   ```

3. Build the app. Point `-Draylib_path` at the folder you just unpacked:

   ```sh
   zig build -Doptimize=ReleaseFast -Draylib_path=/path/to/raylib-5.5_linux_amd64
   ```

4. Start it:

   ```sh
   ./zig-out/bin/diskviz
   ```

The app looks for the Liberation fonts first, then DejaVu.
On Ubuntu, `sudo apt install fonts-liberation` adds them if they are missing.

On Linux, the right-click menu can open folders, but **Delete** works on Windows only.

[Back to Top](#getting-started)

## macOS

macOS support is untested.
The build should work with raylib from Homebrew:

```sh
brew install raylib pkg-config
zig build -Doptimize=ReleaseFast
```

On macOS, **Delete** in the right-click menu is not available.

[Back to Top](#getting-started)

## Build Options

Pass these to `zig build`.

| Option | What it does |
|---|---|
| `-Doptimize=ReleaseFast` | Builds a fast release version. Leave it off for a debug build. |
| `-Draylib_path=<folder>` | Uses the raylib in `<folder>`, which must hold `lib` and `include`. On Windows, this replaces the copy in `vendor/raylib`. |
| `-Dtarget=<target>` | Builds for another system, such as `x86_64-windows-gnu`. |

Release builds on Windows open only the app window.
Debug builds also open a console window, so error messages stay visible.

If you use your own raylib on Windows, pick the MinGW-w64 build.
The Microsoft Visual C++ (MSVC) build will not link with the default target.

[Back to Top](#getting-started)

## Running the Tests

Run all the unit tests with:

```sh
zig build test
```

There are 20 tests. They check:

- the byte size labels, like `1.4 GB`
- the treemap layout
- the scanner, using small folders it creates and then deletes
- the settings file
- the text tools that cut long names short

The tests do not open a window, so they also run on a server or in a terminal.

[Back to Top](#getting-started)

---

[Back to README](./README.md)
