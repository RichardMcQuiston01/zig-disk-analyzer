//! Background filesystem scanner.
//!
//! A `Scan` walks a directory tree on its own OS thread and builds a `Node`
//! tree in a private arena. Results are published live: every file and folder
//! is linked into its parent the moment it is found, and its size is added to
//! every ancestor, so the UI can show (and drill into) a partial tree that
//! keeps growing.
//!
//! Concurrency contract:
//!   * The worker is the only writer. It mutates `size` and `children` only
//!     while holding `mutex`, and each publish updates a node and all of its
//!     ancestors atomically, so a locked read always sees consistent totals.
//!   * Readers on other threads call `snapshotChildren`, which copies child
//!     pointers *and* their sizes under the lock. Immutable fields (`name`,
//!     `is_dir`, `parent`) can be read lock-free once a node is visible.
//!   * Node pointers are stable: nodes are arena-allocated and never moved.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const model = @import("model.zig");

const Node = model.Node;

pub const Phase = enum(u8) { idle, scanning, done, cancelled, failed };

/// A child pointer plus its size, captured together under the scan lock.
pub const ChildSnapshot = struct {
    node: *Node,
    size: u64,
};

/// Minimal spinlock. Critical sections are a pointer append plus an ancestor
/// size walk (a few dozen instructions), and the UI takes the lock a few times
/// per second, so a spinlock is lighter than the io-threaded `std.Io.Mutex`
/// and needs no `Io` handle on the UI thread.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

pub const Scan = struct {
    gpa: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    arena: std.mem.Allocator,
    root: *Node,
    root_path: []const u8,

    mutex: SpinLock = .{},
    thread: ?std.Thread = null,
    cancel_flag: std.atomic.Value(bool),
    bytes_done: std.atomic.Value(u64),
    items_done: std.atomic.Value(u64),
    phase_raw: std.atomic.Value(u8),

    /// Begin scanning `path` (must be an absolute path). The returned scan owns
    /// a worker thread and an arena; release it with `deinit`.
    pub fn start(gpa: std.mem.Allocator, path: []const u8) !*Scan {
        const self = try gpa.create(Scan);
        errdefer gpa.destroy(self);

        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena_state);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const path_copy = try arena.dupe(u8, path);
        const root = try arena.create(Node);
        root.* = .{ .name = path_copy, .is_dir = true };

        self.* = .{
            .gpa = gpa,
            .arena_state = arena_state,
            .arena = arena,
            .root = root,
            .root_path = path_copy,
            .cancel_flag = std.atomic.Value(bool).init(false),
            .bytes_done = std.atomic.Value(u64).init(0),
            .items_done = std.atomic.Value(u64).init(0),
            .phase_raw = std.atomic.Value(u8).init(@intFromEnum(Phase.scanning)),
        };

        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Signal cancellation, join the worker, and free the tree and the scan.
    pub fn deinit(self: *Scan) void {
        self.cancel_flag.store(true, .monotonic);
        self.wait();
        self.arena_state.deinit();
        self.gpa.destroy(self.arena_state);
        self.gpa.destroy(self);
    }

    /// Block until the worker finishes (used by tests / headless callers).
    pub fn wait(self: *Scan) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn phase(self: *Scan) Phase {
        return @enumFromInt(self.phase_raw.load(.monotonic));
    }

    pub fn isScanning(self: *Scan) bool {
        return self.phase() == .scanning;
    }

    pub fn bytesScanned(self: *Scan) u64 {
        return self.bytes_done.load(.monotonic);
    }

    pub fn itemsScanned(self: *Scan) u64 {
        return self.items_done.load(.monotonic);
    }

    /// Copy `node`'s children and their current sizes into `out`, and return
    /// `node`'s own current size, all from one consistent locked view.
    pub fn snapshotChildren(
        self: *Scan,
        node: *Node,
        out: *std.ArrayList(ChildSnapshot),
        gpa: std.mem.Allocator,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        out.clearRetainingCapacity();
        try out.ensureTotalCapacity(gpa, node.children.items.len);
        for (node.children.items) |child| {
            out.appendAssumeCapacity(.{ .node = child, .size = child.size });
        }
        return node.size;
    }

    /// Unlink `node` (after it was deleted on disk) and subtract its size and
    /// item count from every ancestor. Only valid once the scan has stopped:
    /// mid-scan the worker could still be publishing into this subtree.
    /// Returns false if the node was not found under its parent.
    pub fn removeNode(self: *Scan, node: *Node) bool {
        std.debug.assert(!self.isScanning());
        const parent = node.parent orelse return false;

        self.mutex.lock();
        defer self.mutex.unlock();

        const index = std.mem.indexOfScalar(*Node, parent.children.items, node) orelse return false;
        _ = parent.children.orderedRemove(index);

        const removed_size = node.size;
        var ancestor: ?*Node = parent;
        while (ancestor) |a| : (ancestor = a.parent) {
            a.size -|= removed_size;
        }

        const removed_items = countNodes(node);
        _ = self.items_done.fetchSub(@min(removed_items, self.items_done.load(.monotonic)), .monotonic);
        _ = self.bytes_done.fetchSub(@min(removed_size, self.bytes_done.load(.monotonic)), .monotonic);
        return true;
    }

    /// Current total size of the scanned tree (grows while scanning).
    pub fn rootSize(self: *Scan) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.root.size;
    }

    fn run(self: *Scan) void {
        var threaded = Io.Threaded.init(self.gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var dir = Io.Dir.openDirAbsolute(io, self.root_path, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch {
            self.setPhase(.failed);
            return;
        };
        defer dir.close(io);

        self.scanInto(io, dir, self.root);
        self.setPhase(if (self.cancel_flag.load(.monotonic)) .cancelled else .done);
    }

    fn scanInto(self: *Scan, io: Io, dir: Io.Dir, node: *Node) void {
        var it = dir.iterate();
        while (true) {
            if (self.cancel_flag.load(.monotonic)) return;
            const maybe_entry = it.next(io) catch break;
            const entry = maybe_entry orelse break;
            self.addEntry(io, dir, entry, node);
        }
    }

    /// Create a node for one directory entry, publish it immediately, and
    /// recurse into it if it is a directory.
    fn addEntry(self: *Scan, io: Io, dir: Io.Dir, entry: Io.Dir.Entry, parent: *Node) void {
        // Only the worker allocates from the arena, so this needs no lock.
        const node = self.arena.create(Node) catch return;
        const name = self.arena.dupe(u8, entry.name) catch return;
        node.* = .{ .name = name, .parent = parent };

        switch (entry.kind) {
            .directory => {
                node.is_dir = true;
                // Publish the empty folder first so it shows up right away and
                // grows as its contents are found.
                self.publish(node, 0);
                var sub = dir.openDir(io, name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch {
                    node.unreadable = true;
                    return;
                };
                defer sub.close(io);
                self.scanInto(io, sub, node);
            },
            // Never follow symlinks: count the link itself as negligible to
            // avoid cycles and double-counting the target.
            .sym_link => self.publish(node, 0),
            else => {
                const size: u64 = if (dir.statFile(io, name, .{ .follow_symlinks = false })) |st|
                    st.size
                else |_|
                    self.lockedFileSize(node) orelse 0;
                self.publish(node, size);
                _ = self.bytes_done.fetchAdd(size, .monotonic);
            },
        }
    }

    /// Link `node` into its parent and add `size` to every ancestor, as one
    /// atomic step with respect to readers.
    fn publish(self: *Scan, node: *Node, size: u64) void {
        const parent = node.parent orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        parent.children.append(self.arena, node) catch return;
        node.size = size;
        var ancestor: ?*Node = parent;
        while (ancestor) |a| : (ancestor = a.parent) {
            a.size +|= size;
        }
        _ = self.items_done.fetchAdd(1, .monotonic);
    }

    fn setPhase(self: *Scan, p: Phase) void {
        self.phase_raw.store(@intFromEnum(p), .monotonic);
    }

    /// Size of a file that `stat` could not open. On Windows, files the OS
    /// holds exclusively (pagefile.sys, hiberfil.sys, swapfile.sys) fail to
    /// open, but their size is still available from directory metadata via
    /// GetFileAttributesExW, which does not open the file. Null elsewhere or
    /// on failure.
    fn lockedFileSize(self: *Scan, node: *Node) ?u64 {
        if (builtin.os.tag != .windows) return null;

        const path = buildPathAlloc(self.gpa, node) catch return null;
        defer self.gpa.free(path);
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(self.gpa, path) catch return null;
        defer self.gpa.free(wide);

        var data: win32.FileAttributeData = undefined;
        if (win32.GetFileAttributesExW(wide.ptr, win32.get_file_ex_info_standard, &data) == 0) return null;
        return (@as(u64, data.file_size_high) << 32) | data.file_size_low;
    }
};

/// Number of nodes in the subtree rooted at `node`, including `node`.
fn countNodes(node: *const Node) u64 {
    var total: u64 = 1;
    for (node.children.items) |child| total += countNodes(child);
    return total;
}

/// Full path of `node`, built by walking its (immutable) parent chain.
pub fn buildPathAlloc(gpa: std.mem.Allocator, node: *Node) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var cursor: ?*Node = node;
    while (cursor) |n| : (cursor = n.parent) try parts.append(gpa, n.name);
    std.mem.reverse([]const u8, parts.items);
    return std.fs.path.join(gpa, parts.items);
}

/// The one Win32 call we need that std doesn't wrap.
const win32 = struct {
    const get_file_ex_info_standard: c_int = 0;

    /// WIN32_FILE_ATTRIBUTE_DATA
    const FileAttributeData = extern struct {
        attributes: u32,
        creation_time: [2]u32,
        last_access_time: [2]u32,
        last_write_time: [2]u32,
        file_size_high: u32,
        file_size_low: u32,
    };

    extern "kernel32" fn GetFileAttributesExW(
        file_name: [*:0]const u16,
        info_level: c_int,
        info: *FileAttributeData,
    ) callconv(.winapi) c_int;
};

test "removeNode keeps every total consistent" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    //   root/{keep.bin=100, sub/{a.bin=40, deep/{b.bin=7}}}
    const base = "ztmp_scanner_remove";
    var cwd = Io.Dir.cwd();
    cwd.deleteTree(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};
    try cwd.createDirPath(io, base ++ "/sub/deep");
    // (Zig 0.17 removed the `**` array-repeat operator, so fill a buffer.)
    var fill: [100]u8 = undefined;
    @memset(&fill, 'x');
    try cwd.writeFile(io, .{ .sub_path = base ++ "/keep.bin", .data = fill[0..100] });
    try cwd.writeFile(io, .{ .sub_path = base ++ "/sub/a.bin", .data = fill[0..40] });
    try cwd.writeFile(io, .{ .sub_path = base ++ "/sub/deep/b.bin", .data = fill[0..7] });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = try cwd.realPathFile(io, base, &path_buf);
    const scan = try Scan.start(gpa, path_buf[0..abs_len]);
    defer scan.deinit();
    scan.wait();
    try std.testing.expectEqual(@as(u64, 147), scan.rootSize());
    try std.testing.expectEqual(@as(u64, 5), scan.itemsScanned());

    // Find sub/deep and remove it: 7 bytes and 2 items (deep, b.bin) go away.
    var sub: ?*Node = null;
    for (scan.root.children.items) |c| {
        if (std.mem.eql(u8, c.name, "sub")) sub = c;
    }
    const deep = sub.?.children.items[for (sub.?.children.items, 0..) |c, i| {
        if (std.mem.eql(u8, c.name, "deep")) break i;
    } else unreachable];

    try std.testing.expect(scan.removeNode(deep));
    try std.testing.expectEqual(@as(u64, 140), scan.rootSize());
    try std.testing.expectEqual(@as(u64, 40), sub.?.size);
    try std.testing.expectEqual(@as(usize, 1), sub.?.children.items.len);
    try std.testing.expectEqual(@as(u64, 3), scan.itemsScanned());
    try expectConsistent(scan.root);

    // Removing it again is a no-op that reports not-found.
    try std.testing.expect(!scan.removeNode(deep));
    try std.testing.expectEqual(@as(u64, 140), scan.rootSize());
}

test "buildPathAlloc joins the parent chain" {
    const gpa = std.testing.allocator;
    var root = Node{ .name = "/data", .is_dir = true };
    var sub = Node{ .name = "sub", .is_dir = true, .parent = &root };
    var file = Node{ .name = "f.bin", .parent = &sub };
    const path = try buildPathAlloc(gpa, &file);
    defer gpa.free(path);
    try std.testing.expectEqualStrings("/data/sub/f.bin", path);
}

/// Recursively check that every directory's size equals the sum of its
/// children and that every child points back at its parent.
fn expectConsistent(node: *const Node) !void {
    var sum: u64 = 0;
    for (node.children.items) |child| {
        try std.testing.expectEqual(@as(?*Node, @constCast(node)), child.parent);
        try expectConsistent(child);
        sum += child.size;
    }
    if (node.is_dir) try std.testing.expectEqual(sum, node.size);
}

test "scanner aggregates a known tree" {
    const gpa = std.testing.allocator;

    // Build a temp tree:
    //   root/{a.bin=1000, sub/{b.bin=500, c.bin=24, deep/{d.bin=7}}, empty/}
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "ztmp_scanner_test";
    var cwd = Io.Dir.cwd();
    cwd.deleteTree(io, base) catch {};
    try cwd.createDirPath(io, base ++ "/sub/deep");
    defer cwd.deleteTree(io, base) catch {};
    try cwd.createDirPath(io, base ++ "/empty");

    const zeros = try gpa.alloc(u8, 1000);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    try cwd.writeFile(io, .{ .sub_path = base ++ "/a.bin", .data = zeros[0..1000] });
    try cwd.writeFile(io, .{ .sub_path = base ++ "/sub/b.bin", .data = zeros[0..500] });
    try cwd.writeFile(io, .{ .sub_path = base ++ "/sub/c.bin", .data = zeros[0..24] });
    try cwd.writeFile(io, .{ .sub_path = base ++ "/sub/deep/d.bin", .data = zeros[0..7] });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = try cwd.realPathFile(io, base, &path_buf);
    const abs = path_buf[0..abs_len];

    const scan = try Scan.start(gpa, abs);
    defer scan.deinit();
    scan.wait();

    try std.testing.expectEqual(Phase.done, scan.phase());
    try std.testing.expectEqual(@as(u64, 1531), scan.rootSize());
    try std.testing.expectEqual(@as(u64, 1531), scan.bytesScanned());
    // a.bin, sub, b.bin, c.bin, deep, d.bin, empty
    try std.testing.expectEqual(@as(u64, 7), scan.itemsScanned());

    // Every directory total equals the sum of its children, all the way down.
    try expectConsistent(scan.root);

    // Top level via the snapshot API: a.bin (1000), sub (531), empty (0).
    var kids: std.ArrayList(ChildSnapshot) = .empty;
    defer kids.deinit(gpa);
    const root_size = try scan.snapshotChildren(scan.root, &kids, gpa);
    try std.testing.expectEqual(@as(u64, 1531), root_size);
    try std.testing.expectEqual(@as(usize, 3), kids.items.len);

    var sub_size: ?u64 = null;
    for (kids.items) |k| {
        if (std.mem.eql(u8, k.node.name, "sub")) sub_size = k.size;
    }
    try std.testing.expectEqual(@as(?u64, 531), sub_size);
}

test "snapshot sizes stay consistent while the tree is growing" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A tree big enough that we can sample it mid-scan.
    const base = "ztmp_scanner_live";
    var cwd = Io.Dir.cwd();
    cwd.deleteTree(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};
    var name_buf: [64]u8 = undefined;
    for (0..40) |d| {
        const dir_name = try std.fmt.bufPrint(&name_buf, base ++ "/d{d}", .{d});
        try cwd.createDirPath(io, dir_name);
        for (0..25) |f| {
            var file_buf: [96]u8 = undefined;
            const file_name = try std.fmt.bufPrint(&file_buf, "{s}/f{d}.bin", .{ dir_name, f });
            try cwd.writeFile(io, .{ .sub_path = file_name, .data = "0123456789" });
        }
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = try cwd.realPathFile(io, base, &path_buf);
    const scan = try Scan.start(gpa, path_buf[0..abs_len]);
    defer scan.deinit();

    // Sample repeatedly while the worker runs: in every snapshot the parent
    // total must equal the sum of the child sizes captured with it.
    var kids: std.ArrayList(ChildSnapshot) = .empty;
    defer kids.deinit(gpa);
    var samples: usize = 0;
    while (samples < 2000) : (samples += 1) {
        const parent_size = try scan.snapshotChildren(scan.root, &kids, gpa);
        var sum: u64 = 0;
        for (kids.items) |k| sum += k.size;
        try std.testing.expectEqual(parent_size, sum);
        if (!scan.isScanning()) break;
    }

    scan.wait();
    try std.testing.expectEqual(@as(u64, 40 * 25 * 10), scan.rootSize());
    try expectConsistent(scan.root);
}
