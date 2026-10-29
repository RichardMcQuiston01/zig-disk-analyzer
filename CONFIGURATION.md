# Configuration

[Back to README](./README.md)

| [Settings Window](#settings-window) | [Font](#font) | [Text Size](#text-size) | [Settings File](#settings-file) |

## Settings Window

Click **Settings** to open it.
The button is on the drive list screen and in the top bar while you browse.

Each choice takes effect right away.
A preview line shows how text will look.
To close the window, click **Done**, press Esc, or click outside it.

[Back to Top](#configuration)

## Font

Pick one of three fonts. Arial is the default.

| Choice | File used on Windows |
|---|---|
| Arial | `arial.ttf` |
| Times New Roman | `times.ttf` |
| Courier | `cour.ttf` (Courier New) |

On Windows, the app loads these from the Windows `Fonts` folder.
On Linux, it uses the Liberation fonts, which have the same letter widths as these fonts. If those are missing, it uses DejaVu.

If the font file cannot be found, the app uses raylib's built-in font.
The settings window then says `Font file not found - using the built-in font`.
The built-in font only has basic English letters, so other letters show as `?`.

[Back to Top](#configuration)

## Text Size

| Choice | Size |
|---|---|
| Smaller | 80% of normal |
| Normal | The default size |
| Larger | 120% of normal |

The whole layout grows or shrinks with the text, including rows, buttons, and icons.

The first time a size is used, the app draws each letter at that exact size.
This keeps text sharp, but it can cause a short pause after you change a setting.

[Back to Top](#configuration)

## Settings File

Your choices are saved in `diskviz.ini`, in the same folder as the app.
After a normal build, that is `zig-out\bin\diskviz.ini`.

The file looks like this:

```ini
# Disk Usage Analyzer settings
font=arial
size=normal
```

| Key | Allowed values |
|---|---|
| `font` | `arial`, `times`, `courier` |
| `size` | `smaller`, `normal`, `larger` |

You can edit the file by hand while the app is closed.
A value the app does not know is ignored, and that setting uses its default.
Delete the file to go back to all defaults.

The file is listed in `.gitignore`, so your settings never end up in the repo.

[Back to Top](#configuration)

---

[Back to README](./README.md)
