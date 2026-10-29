//! Text rendering with a user-selectable font and size.
//!
//! raylib rasterizes a TTF into a texture at one pixel size, and scaling that
//! texture looks soft. So each font is loaded at every exact pixel size the UI
//! asks for, cached, and drawn at whole-pixel positions: text stays crisp at
//! all three size settings.
//!
//! Callers pass *base* sizes (the sizes at "Normal"); this module applies the
//! size factor. If the chosen font file can't be found, it falls back to
//! raylib's built-in font (ASCII only).

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib.zig");
const settings = @import("settings.zig");

const FontChoice = settings.FontChoice;
const SizeChoice = settings.SizeChoice;

/// Unicode ranges to rasterize: Latin (incl. accented), Greek, Cyrillic, and
/// common punctuation/symbols. This lets file names with these characters
/// render instead of showing `?`. Scripts outside these ranges (e.g. CJK)
/// would need a font that has them.
const glyph_ranges = [_][2]u21{
    .{ 0x0020, 0x007E }, // ASCII
    .{ 0x00A0, 0x024F }, // Latin-1 Supplement, Latin Extended-A/B
    .{ 0x0370, 0x03FF }, // Greek
    .{ 0x0400, 0x04FF }, // Cyrillic
    .{ 0x2010, 0x2027 }, // dashes, quotes, bullet, ellipsis
    .{ 0x2030, 0x203A }, // per mille, angle quotes
    .{ 0x20AC, 0x20AC }, // euro
    .{ 0x2122, 0x2122 }, // trademark
};

const glyph_count: usize = blk: {
    var n: usize = 0;
    for (glyph_ranges) |r| n += r[1] - r[0] + 1;
    break :blk n;
};

/// raylib takes a non-const `int*` for the code point list (it only reads it),
/// so keep a mutable copy.
var codepoints: [glyph_count]c_int = blk: {
    @setEvalBranchQuota(20_000);
    var out: [glyph_count]c_int = undefined;
    var i: usize = 0;
    for (glyph_ranges) |r| {
        var cp: u21 = r[0];
        while (cp <= r[1]) : (cp += 1) {
            out[i] = cp;
            i += 1;
        }
    }
    break :blk out;
};

const max_cached_sizes = 24;

const CachedFont = struct {
    pixel_size: i32,
    font: rl.Font,
};

pub const Typography = struct {
    font_choice: FontChoice,
    size_choice: SizeChoice,

    /// Resolved path of the chosen font file. Stored as a length into
    /// `path_buf`, never as a slice: `Typography` is copied by value, and a
    /// slice into its own buffer would dangle after the copy. Use `path()`.
    path_buf: [512:0]u8 = undefined,
    path_len: ?usize = null,

    cache: [max_cached_sizes]CachedFont = undefined,
    cache_len: usize = 0,

    /// Must be called after the window (GL context) exists.
    pub fn init(choice: settings.Settings) Typography {
        var t = Typography{ .font_choice = choice.font, .size_choice = choice.size };
        t.resolvePath();
        return t;
    }

    /// Must be called before the window closes (fonts live in GPU memory).
    pub fn deinit(self: *Typography) void {
        self.unloadAll();
    }

    pub fn setFont(self: *Typography, choice: FontChoice) void {
        if (choice == self.font_choice) return;
        self.unloadAll();
        self.font_choice = choice;
        self.resolvePath();
    }

    pub fn setSize(self: *Typography, choice: SizeChoice) void {
        // Cached fonts are keyed by pixel size, so they stay valid.
        self.size_choice = choice;
    }

    /// True when a TTF is in use (false = built-in ASCII-only fallback).
    pub fn usingTtf(self: *const Typography) bool {
        return self.path_len != null;
    }

    /// The resolved font path, or null for the built-in font.
    fn path(self: *const Typography) ?[*:0]const u8 {
        const len = self.path_len orelse return null;
        std.debug.assert(self.path_buf[len] == 0);
        return @ptrCast(&self.path_buf);
    }

    pub fn factor(self: *const Typography) f32 {
        return self.size_choice.factor();
    }

    /// Scale a layout metric (padding, row height, ...) by the size setting.
    pub fn s(self: *const Typography, value: f32) f32 {
        return value * self.factor();
    }

    /// Pixel size for a base text size at the current setting.
    pub fn px(self: *const Typography, base: f32) i32 {
        return @max(6, @as(i32, @intFromFloat(@round(base * self.factor()))));
    }

    pub fn pxF(self: *const Typography, base: f32) f32 {
        return @floatFromInt(self.px(base));
    }

    pub fn draw(self: *Typography, text: [*:0]const u8, x: f32, y: f32, base: f32, color: rl.Color) void {
        const size = self.px(base);
        const font = self.fontFor(size);
        const pos = rl.Vector2{ .x = @round(x), .y = @round(y) };
        rl.drawTextEx(font, text, pos, @floatFromInt(size), self.spacing(size), color);
    }

    /// Draw text vertically centered in a band starting at `top` of `height`.
    pub fn drawCentered(self: *Typography, text: [*:0]const u8, x: f32, top: f32, height: f32, base: f32, color: rl.Color) void {
        self.draw(text, x, top + (height - self.pxF(base)) / 2, base, color);
    }

    pub fn measure(self: *Typography, text: [*:0]const u8, base: f32) f32 {
        const size = self.px(base);
        return rl.measureTextEx(self.fontFor(size), text, @floatFromInt(size), self.spacing(size)).x;
    }

    /// Copy `text` into `buf` as a NUL-terminated string that fits within
    /// `max_width`, cutting at a UTF-8 boundary and appending "..." if needed.
    pub fn fit(self: *Typography, buf: []u8, text: []const u8, max_width: f32, base: f32) [:0]const u8 {
        const full = copyZ(buf, text, text.len);
        if (max_width <= 0 or self.measure(full, base) <= max_width) return full;

        // Binary search the longest prefix (in bytes) that fits with "...".
        var lo: usize = 0;
        var hi: usize = @min(text.len, buf.len - 4);
        while (lo < hi) {
            const mid = utf8Boundary(text, (lo + hi + 1) / 2);
            if (mid <= lo) break;
            const candidate = withEllipsis(buf, text, mid);
            if (self.measure(candidate, base) <= max_width) lo = mid else hi = mid - 1;
        }
        return withEllipsis(buf, text, utf8Boundary(text, lo));
    }

    // --- internals -------------------------------------------------------------

    fn spacing(self: *const Typography, size: i32) f32 {
        // TTF glyph advances already include natural spacing. The built-in
        // font needs raylib's own DrawText spacing rule: size / 10.
        if (self.usingTtf()) return 0;
        return @floatFromInt(@divTrunc(@max(size, 10), 10));
    }

    fn fontFor(self: *Typography, size: i32) rl.Font {
        for (self.cache[0..self.cache_len]) |entry| {
            if (entry.pixel_size == size) return entry.font;
        }
        const font_path = self.path() orelse return rl.fontDefault();

        if (self.cache_len == max_cached_sizes) self.unloadAll();
        const font = rl.loadFontEx(font_path, size, &codepoints);
        if (!rl.isFontValid(font) or font.texture.id == 0) {
            // Unreadable font file: stop retrying and use the built-in font.
            self.path_len = null;
            return rl.fontDefault();
        }
        rl.setTextureFilter(font.texture, rl.texture_filter_point);
        self.cache[self.cache_len] = .{ .pixel_size = size, .font = font };
        self.cache_len += 1;
        return font;
    }

    fn unloadAll(self: *Typography) void {
        for (self.cache[0..self.cache_len]) |entry| rl.unloadFont(entry.font);
        self.cache_len = 0;
    }

    fn resolvePath(self: *Typography) void {
        self.path_len = null;
        var dir_buf: [260]u8 = undefined;
        const fonts_dir = systemFontsDir(&dir_buf);
        for (candidateFiles(self.font_choice)) |file| {
            const full = if (std.fs.path.isAbsolute(file))
                std.fmt.bufPrint(self.path_buf[0 .. self.path_buf.len - 1], "{s}", .{file})
            else
                std.fmt.bufPrint(self.path_buf[0 .. self.path_buf.len - 1], "{s}{s}", .{ fonts_dir, file });
            const written = full catch continue;
            self.path_buf[written.len] = 0;
            if (rl.fileExists(self.path_buf[0..written.len :0].ptr)) {
                self.path_len = written.len;
                return;
            }
        }
    }
};

/// Font files to try for each choice, in order. Relative names are resolved
/// against the system fonts directory (Windows); absolute paths are used as-is.
fn candidateFiles(choice: FontChoice) []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (choice) {
            .arial => &.{"arial.ttf"},
            .times => &.{"times.ttf"},
            .courier => &.{"cour.ttf"},
        },
        .macos => switch (choice) {
            .arial => &.{ "/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf" },
            .times => &.{ "/System/Library/Fonts/Supplemental/Times New Roman.ttf", "/Library/Fonts/Times New Roman.ttf" },
            .courier => &.{ "/System/Library/Fonts/Supplemental/Courier New.ttf", "/Library/Fonts/Courier New.ttf" },
        },
        // Linux: metric-compatible Liberation fonts, then DejaVu.
        else => switch (choice) {
            .arial => &.{
                "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
                "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            },
            .times => &.{
                "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf",
                "/usr/share/fonts/liberation/LiberationSerif-Regular.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
            },
            .courier => &.{
                "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
                "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
            },
        },
    };
}

/// `<windows dir>\Fonts\` on Windows (e.g. `C:\Windows\Fonts\`); empty elsewhere.
fn systemFontsDir(buf: []u8) []const u8 {
    if (builtin.os.tag != .windows) return "";
    const n = win32.GetWindowsDirectoryA(buf.ptr, @intCast(buf.len));
    const windows_dir: []const u8 = if (n > 0 and n < buf.len - 8) buf[0..n] else "C:\\Windows";
    var tmp: [268]u8 = undefined;
    const joined = std.fmt.bufPrint(&tmp, "{s}\\Fonts\\", .{windows_dir}) catch return "C:\\Windows\\Fonts\\";
    @memcpy(buf[0..joined.len], joined);
    return buf[0..joined.len];
}

const win32 = struct {
    extern "kernel32" fn GetWindowsDirectoryA(buffer: [*]u8, size: c_uint) callconv(.winapi) c_uint;
};

fn copyZ(buf: []u8, text: []const u8, len: usize) [:0]const u8 {
    const n = @min(len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

fn withEllipsis(buf: []u8, text: []const u8, len: usize) [:0]const u8 {
    const n = @min(len, buf.len - 4);
    @memcpy(buf[0..n], text[0..n]);
    @memcpy(buf[n .. n + 3], "...");
    buf[n + 3] = 0;
    return buf[0 .. n + 3 :0];
}

/// Largest index <= `index` that doesn't split a UTF-8 sequence.
fn utf8Boundary(text: []const u8, index: usize) usize {
    var i = @min(index, text.len);
    while (i > 0 and i < text.len and (text[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

test "utf8Boundary never splits a code point" {
    const text = "ab\u{00E9}cd"; // 'é' is 2 bytes at index 2..3
    try std.testing.expectEqual(@as(usize, 2), utf8Boundary(text, 2));
    try std.testing.expectEqual(@as(usize, 2), utf8Boundary(text, 3));
    try std.testing.expectEqual(@as(usize, 4), utf8Boundary(text, 4));
    try std.testing.expectEqual(@as(usize, text.len), utf8Boundary(text, 99));
}

test "withEllipsis truncates and terminates" {
    var buf: [16]u8 = undefined;
    const out = withEllipsis(&buf, "hello world", 5);
    try std.testing.expectEqualStrings("hello...", out);
    try std.testing.expectEqual(@as(u8, 0), out.ptr[out.len]);
}

test "glyph set covers the expected ranges" {
    try std.testing.expectEqual(@as(c_int, 0x20), codepoints[0]);
    try std.testing.expectEqual(@as(c_int, 0x2122), codepoints[glyph_count - 1]);
    // ASCII 95 + Latin 432 + Greek 144 + Cyrillic 256 + punct 24 + 11 + 1 + 1
    try std.testing.expectEqual(@as(usize, 964), glyph_count);
}
