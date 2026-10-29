//! Human-readable formatting helpers.
//!
//! These are pure functions that format into a caller-provided buffer so the
//! hot render loop never allocates. `bytesZ` returns a NUL-terminated slice
//! suitable for raylib's C text functions.

const std = @import("std");

const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB", "EB" };

/// Format a byte count like `1.4 GB` into `buf`. Returns the written slice.
/// Values under 1 KB are shown as whole bytes. On overflow the slice is empty.
pub fn bytes(buf: []u8, n: u64) []const u8 {
    var value: f64 = @floatFromInt(n);
    var unit_index: usize = 0;
    while (value >= 1024.0 and unit_index < units.len - 1) : (unit_index += 1) {
        value /= 1024.0;
    }
    if (unit_index == 0) {
        return std.fmt.bufPrint(buf, "{d} B", .{n}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit_index] }) catch buf[0..0];
}

/// Format `fmt`/`args` into `buf` and NUL-terminate it, returning a sentinel
/// slice for C interop. `buf` must have room for the text plus one NUL byte.
/// 0.17's std has no `bufPrintZ`, so we terminate by hand.
fn printZ(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    const written = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch buf[0..0];
    buf[written.len] = 0;
    return buf[0..written.len :0];
}

/// Same as `bytes` but returns a NUL-terminated slice for C interop (raylib).
pub fn bytesZ(buf: []u8, n: u64) [:0]const u8 {
    var value: f64 = @floatFromInt(n);
    var unit_index: usize = 0;
    while (value >= 1024.0 and unit_index < units.len - 1) : (unit_index += 1) {
        value /= 1024.0;
    }
    if (unit_index == 0) return printZ(buf, "{d} B", .{n});
    return printZ(buf, "{d:.1} {s}", .{ value, units[unit_index] });
}

/// Format a percentage like `42.8%` into a NUL-terminated slice.
pub fn percentZ(buf: []u8, fraction: f64) [:0]const u8 {
    const clamped = std.math.clamp(fraction, 0.0, 1.0) * 100.0;
    return printZ(buf, "{d:.1}%", .{clamped});
}

test "bytes formats magnitudes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", bytes(&buf, 512));
    try std.testing.expectEqualStrings("1.0 KB", bytes(&buf, 1024));
    try std.testing.expectEqualStrings("1.5 KB", bytes(&buf, 1536));
    try std.testing.expectEqualStrings("1.0 MB", bytes(&buf, 1024 * 1024));
    try std.testing.expectEqualStrings("2.0 GB", bytes(&buf, 2 * 1024 * 1024 * 1024));
}

test "bytesZ is nul terminated" {
    var buf: [32]u8 = undefined;
    const s = bytesZ(&buf, 1024 * 1024);
    try std.testing.expectEqualStrings("1.0 MB", s);
    try std.testing.expectEqual(@as(u8, 0), s.ptr[s.len]);
}
