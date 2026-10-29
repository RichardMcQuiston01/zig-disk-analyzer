# Disk Usage Analyzer

- Author: [Richard McQuiston](mailto:richard.mcquiston@gmail.com)
- Website: https://richardmcquiston.com/

## Table of Contents

| [Overview](#overview) | [Getting Started](#getting-started) | [Features](#features) | [More Information](#more-information) | [Buy Me a Coffee](#buy-me-a-coffee) | [License](#license) | [Copyright](#copyright) |

## Overview

Disk Usage Analyzer shows you what is using the space on a drive.
Pick a drive, and the app scans it in the background.
The results fill in live, in two views side by side.
The list view shows each file and folder with its size, largest first.
The treemap view draws each one as a tile, and a bigger tile means a bigger item.

The app is a small desktop program written in [Zig](https://ziglang.org/).
It uses [raylib](https://www.raylib.com/) for graphics.
Windows is the main target, and it also runs on Linux.

[Back to Top](#table-of-contents)

## Getting Started

### Prerequisites

- Zig 0.16.0 or 0.17.0. Check your version with `zig version`.
- On Windows, nothing else. The repo includes a copy of raylib 5.5 in `vendor/raylib`.
- On Linux, the raylib 5.5 Linux release and two system packages. See [Getting Started](./GETTING_STARTED.md#linux).

### Installation

1. Clone the repo:

   ```sh
   git clone https://github.com/RichardMcQuiston01/zig-disk-analyzer.git
   cd zig-disk-analyzer
   ```

2. Build the app:

   ```sh
   zig build -Doptimize=ReleaseFast
   ```

The app is saved as `zig-out\bin\diskviz.exe` on Windows, or `zig-out/bin/diskviz` on Linux.
For Linux steps and build options, see [Getting Started](./GETTING_STARTED.md).

### Usage

1. Start the app with `zig build run -Doptimize=ReleaseFast`, or open `zig-out\bin\diskviz.exe`.
2. Click a drive.
3. Watch the list and the treemap fill in. Click any folder to look inside it.

| Action | How |
|---|---|
| Open a folder | Click its row in the list, or its tile in the treemap |
| Go back up | Click **Up**, or click a folder name in the path at the top |
| Scroll the list | Use the mouse wheel over the list |
| Open, show, or delete an item | Right-click its row or tile |
| Change the font or text size | Click **Settings** |
| Scan the same drive again | Click **Rescan** |
| Pick another drive | Click **Change Drive** |

### Examples

**Find what is filling up drive C**

1. Start the app and click `C:\`.
2. The largest item is at the top of the list. It is also the largest tile.
3. Click it to see what is inside. Repeat until you find the cause.

**Free up space safely**

1. Wait for the scan to finish.
2. Right-click a file or folder you no longer need.
3. Click **Delete (to Recycle Bin)**, then click **Move to Recycle Bin**.
4. Empty the Recycle Bin to get the space back.

**Make the text bigger**

1. Click **Settings**.
2. Under **Text size**, click **Larger**. The app saves your choice for next time.

[Back to Top](#table-of-contents)

## Features

- Results appear while the scan runs, so you do not have to wait for it to finish.
- A list view and a treemap view show the same folder side by side.
- A right-click menu can open a folder, show a file in its folder, or move an item to the Recycle Bin.
- Settings let you pick a font (Arial, Times New Roman, or Courier) and a text size.
- Names with accented, Greek, or Cyrillic letters show correctly.

See [Features](./FEATURES.md) for how each part works.

[Back to Top](#table-of-contents)

## More Information

- [Getting Started](./GETTING_STARTED.md): full build steps for Windows and Linux, build options, and tests.
- [Features](./FEATURES.md): the views, live scanning, the right-click menu, and how sizes are counted.
- [Configuration](./CONFIGURATION.md): the settings and the settings file.
- [Tech Stack](./TECH_STACK.md): the tools, the project layout, and design notes.
- [Troubleshooting](./TROUBLESHOOTING.md): fixes for common problems.
- [Ideas](./IDEAS.md): planned improvements.

[Back to Top](#table-of-contents)

## Buy Me a Coffee

If this app, code, or repository has helped you or someone you know, please consider donating. I appreciate any help to offset the costs of development and/or AI Credits.

[**Donate via Stripe**](https://donate.stripe.com/00w5kD3Gj1Xo9v7gVOcs800), or scan:

[![Donate via Stripe](./donate.svg)](https://donate.stripe.com/00w5kD3Gj1Xo9v7gVOcs800)

[Back to Top](#table-of-contents)

## License

Apache 2

[Back to Top](#table-of-contents)

## Copyright

(c)2026 Richard McQuiston. All rights reserved.

[Back to Top](#table-of-contents)
