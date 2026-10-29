//! Enumerate the "drives" / roots the user can choose to scan.
//!
//! Windows: probe drive letters A:\ .. Z:\ and keep the ones that open.
//! Unix:    the filesystem root plus any mounted volumes under the usual
//!          mount points. No environment access is required (the 0.17 env API
//!          is io-threaded); the user can drill into their home from `/`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Root = struct {
    /// Absolute path to scan (owned by the caller-supplied allocator).
    path: []const u8,
    /// Short label for the picker button.
    label: []const u8,
};

pub fn enumerate(arena: std.mem.Allocator, io: Io) ![]Root {
    var list: std.ArrayList(Root) = .empty;

    switch (builtin.os.tag) {
        .windows => {
            var letter: u8 = 'A';
            while (letter <= 'Z') : (letter += 1) {
                const path = [_]u8{ letter, ':', '\\' };
                if (canOpen(io, &path)) {
                    const owned = try arena.dupe(u8, &path);
                    try list.append(arena, .{ .path = owned, .label = owned });
                }
            }
        },
        else => {
            try addRoot(arena, io, &list, "/", "/");
            inline for (.{ "/Volumes", "/media", "/mnt" }) |mount_base| {
                addChildren(arena, io, &list, mount_base) catch {};
            }
        },
    }

    return list.toOwnedSlice(arena);
}

fn addRoot(
    arena: std.mem.Allocator,
    io: Io,
    list: *std.ArrayList(Root),
    path: []const u8,
    label: []const u8,
) !void {
    if (!canOpen(io, path)) return;
    try list.append(arena, .{
        .path = try arena.dupe(u8, path),
        .label = try arena.dupe(u8, label),
    });
}

/// Add each sub-directory of `base` (e.g. every volume under /Volumes).
fn addChildren(
    arena: std.mem.Allocator,
    io: Io,
    list: *std.ArrayList(Root),
    base: []const u8,
) !void {
    var dir = Io.Dir.openDirAbsolute(io, base, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const entry = (it.next(io) catch break) orelse break;
        if (entry.kind != .directory) continue;
        const path = try std.fs.path.join(arena, &.{ base, entry.name });
        try list.append(arena, .{ .path = path, .label = try arena.dupe(u8, entry.name) });
    }
}

fn canOpen(io: Io, path: []const u8) bool {
    var dir = Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}
