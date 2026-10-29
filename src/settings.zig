//! User settings: font family and text size.
//!
//! Pure data plus a tiny `key=value` text format, so it is unit-testable with
//! no raylib or filesystem. Reading and writing the file is done by the UI.

const std = @import("std");

pub const FontChoice = enum {
    arial,
    times,
    courier,

    pub fn label(self: FontChoice) [:0]const u8 {
        return switch (self) {
            .arial => "Arial",
            .times => "Times New Roman",
            .courier => "Courier",
        };
    }
};

pub const SizeChoice = enum {
    smaller,
    normal,
    larger,

    pub fn label(self: SizeChoice) [:0]const u8 {
        return switch (self) {
            .smaller => "Smaller",
            .normal => "Normal",
            .larger => "Larger",
        };
    }

    /// Multiplier applied to every text size and to layout metrics.
    pub fn factor(self: SizeChoice) f32 {
        return switch (self) {
            .smaller => 0.8,
            .normal => 1.0,
            .larger => 1.2,
        };
    }
};

pub const Settings = struct {
    font: FontChoice = .arial,
    size: SizeChoice = .normal,
};

pub const file_name = "diskviz.ini";

/// Parse `key=value` lines. Unknown keys, bad values, blank lines and `#`
/// comments are ignored, so a damaged file falls back to defaults per key.
pub fn parse(text: []const u8) Settings {
    var result: Settings = .{};
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "font")) {
            if (std.meta.stringToEnum(FontChoice, value)) |f| result.font = f;
        } else if (std.mem.eql(u8, key, "size")) {
            if (std.meta.stringToEnum(SizeChoice, value)) |s| result.size = s;
        }
    }
    return result;
}

/// Serialize to the `key=value` format as a NUL-terminated string in `buf`.
pub fn format(buf: []u8, settings: Settings) ?[:0]u8 {
    const written = std.fmt.bufPrint(
        buf[0 .. buf.len - 1],
        "# Disk Usage Analyzer settings\nfont={s}\nsize={s}\n",
        .{ @tagName(settings.font), @tagName(settings.size) },
    ) catch return null;
    buf[written.len] = 0;
    return buf[0..written.len :0];
}

test "parse round-trips format" {
    var buf: [128]u8 = undefined;
    const original = Settings{ .font = .courier, .size = .larger };
    const text = format(&buf, original).?;
    const parsed = parse(text);
    try std.testing.expectEqual(original, parsed);
}

test "parse tolerates junk and keeps defaults" {
    const parsed = parse("# comment\r\n\nfont = times \nsize=gigantic\nbogus=1\nnoequals\n");
    try std.testing.expectEqual(FontChoice.times, parsed.font);
    try std.testing.expectEqual(SizeChoice.normal, parsed.size);
    try std.testing.expectEqual(Settings{}, parse(""));
}

test "size factors are 80/100/120 percent" {
    try std.testing.expectEqual(@as(f32, 0.8), SizeChoice.smaller.factor());
    try std.testing.expectEqual(@as(f32, 1.0), SizeChoice.normal.factor());
    try std.testing.expectEqual(@as(f32, 1.2), SizeChoice.larger.factor());
}
