//! The scanned filesystem tree.
//!
//! A `Node` is either a file or a directory. Directory `size` is the aggregate
//! of its subtree. Nodes are allocated from a scan-owned arena, so there is no
//! per-node free; the whole tree is released at once when a scan is discarded.
//!
//! While a scan is running, `size` and `children` are mutated by the scanner
//! thread under the scan lock. Readers on other threads must go through
//! `Scan.snapshotChildren`, never read those two fields directly.

const std = @import("std");

pub const Node = struct {
    /// Base name (the full path for the scan root). Owned by the scan arena.
    name: []const u8,
    /// Bytes on disk. For directories this is the aggregate subtree size.
    size: u64 = 0,
    is_dir: bool = false,
    /// Set when a directory could not be opened (permissions, vanished).
    unreadable: bool = false,
    /// Containing directory; null only for the scan root.
    parent: ?*Node = null,
    children: std.ArrayList(*Node) = .empty,

    pub fn sortChildrenBySizeDesc(self: *Node) void {
        std.mem.sort(*Node, self.children.items, {}, cmpSizeDesc);
    }
};

fn cmpSizeDesc(_: void, a: *Node, b: *Node) bool {
    return a.size > b.size;
}

/// Fraction of `parent_size` occupied by `size`, in 0..1. Safe when the parent
/// is empty.
pub fn fractionOf(size: u64, parent_size: u64) f64 {
    if (parent_size == 0) return 0;
    return @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(parent_size));
}

test "sort orders children largest first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root = Node{ .name = "root", .is_dir = true };
    const sizes = [_]u64{ 10, 500, 3, 42 };
    for (sizes) |s| {
        const child = try arena.create(Node);
        child.* = .{ .name = "x", .size = s, .parent = &root };
        try root.children.append(arena, child);
        root.size += s;
    }
    root.sortChildrenBySizeDesc();

    try std.testing.expectEqual(@as(u64, 500), root.children.items[0].size);
    try std.testing.expectEqual(@as(u64, 42), root.children.items[1].size);
    try std.testing.expectEqual(@as(u64, 10), root.children.items[2].size);
    try std.testing.expectEqual(@as(u64, 3), root.children.items[3].size);
    try std.testing.expectEqual(@as(u64, 555), root.size);
}

test "fractionOf handles empty parent" {
    try std.testing.expectEqual(@as(f64, 0), fractionOf(0, 0));
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), fractionOf(25, 100), 1e-9);
}
