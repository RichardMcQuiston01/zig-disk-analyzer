//! Platform shell actions: open a folder, reveal a file in its folder, and
//! move an item to the Recycle Bin.
//!
//! Windows uses the Win32 shell APIs directly (wide-char, so any file name
//! works). Elsewhere, opening goes through raylib's `OpenURL` (xdg-open /
//! open), and Recycle Bin support is reported as unavailable.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib.zig");

const is_windows = builtin.os.tag == .windows;

pub const OpenError = error{
    /// The OS refused to open the path (missing, no permission, no handler).
    OpenFailed,
    /// The path contains characters the platform opener can't pass safely.
    UnsupportedPath,
    OutOfMemory,
};

/// Result of a Recycle Bin request, decided by checking the disk afterwards
/// rather than trusting the API's return code alone.
pub const RecycleOutcome = union(enum) {
    /// The item is gone from its original location.
    recycled,
    /// The user declined a Windows prompt (e.g. "too big for the Recycle Bin,
    /// delete permanently?"). Nothing was removed.
    cancelled,
    /// Windows reported success or an error, but the item still exists: some
    /// contents may have moved. Sizes need a rescan.
    partial: u32,
    /// Nothing could be moved. Carries the Windows error code.
    failed: u32,
    /// This platform has no Recycle Bin support in this app.
    unsupported,
};

pub fn recycleSupported() bool {
    return is_windows;
}

/// Open `path` (a folder) in the system file manager.
pub fn openFolder(gpa: std.mem.Allocator, path: []const u8) OpenError!void {
    if (is_windows) {
        ensureComOnThisThread();
        const wide = try toWide(gpa, path);
        defer gpa.free(wide);
        const result = win32.ShellExecuteW(null, win32.verb_open, wide.ptr, null, null, win32.sw_shownormal);
        if (@intFromPtr(result) <= 32) return error.OpenFailed;
        return;
    }
    return openWithRaylib(gpa, path);
}

/// Open the folder containing `path`, with the item selected where supported.
pub fn revealInFolder(gpa: std.mem.Allocator, path: []const u8) OpenError!void {
    if (is_windows) {
        ensureComOnThisThread();
        // explorer.exe /select,"<path>" opens the parent and highlights the item.
        const params = std.fmt.allocPrint(gpa, "/select,\"{s}\"", .{path}) catch return error.OutOfMemory;
        defer gpa.free(params);
        const wide_params = try toWide(gpa, params);
        defer gpa.free(wide_params);
        const result = win32.ShellExecuteW(null, win32.verb_open, win32.explorer_exe, wide_params.ptr, null, win32.sw_shownormal);
        if (@intFromPtr(result) <= 32) return error.OpenFailed;
        return;
    }
    const parent = std.fs.path.dirname(path) orelse path;
    return openWithRaylib(gpa, parent);
}

/// Move `path` (file or folder) to the Recycle Bin. Blocks until done, so call
/// it from a worker thread. `owner` is the window that Windows' own prompts
/// and progress dialog should belong to.
pub fn moveToRecycleBin(gpa: std.mem.Allocator, path: []const u8, owner: ?*anyopaque) RecycleOutcome {
    if (!is_windows) return .unsupported;

    const com_hr = win32.CoInitializeEx(null, win32.coinit_apartmentthreaded | win32.coinit_disable_ole1dde);
    defer if (com_hr >= 0) win32.CoUninitialize();

    const wide = toWide(gpa, path) catch return .{ .failed = win32.error_not_enough_memory };
    defer gpa.free(wide);

    // The item must exist now. Otherwise "gone afterwards" (below) would
    // wrongly read as success, and Windows would ask the confusing "can't be
    // recycled, delete permanently instead?" about something already gone.
    if (win32.GetFileAttributesW(wide.ptr) == win32.invalid_file_attributes) {
        return .{ .failed = win32.error_file_not_found };
    }

    // pFrom must be double-NUL-terminated (it's a list of paths).
    const from = gpa.alloc(u16, wide.len + 2) catch return .{ .failed = win32.error_not_enough_memory };
    defer gpa.free(from);
    @memcpy(from[0..wide.len], wide[0..wide.len]);
    from[wide.len] = 0;
    from[wide.len + 1] = 0;

    var op = win32.SHFILEOPSTRUCTW{
        .hwnd = owner,
        .w_func = win32.fo_delete,
        .p_from = from.ptr,
        .p_to = null,
        // ALLOWUNDO = Recycle Bin. NOCONFIRMATION because the app already
        // asked. WANTNUKEWARNING still makes Windows ask before anything would
        // be deleted permanently (too large for the bin, or a drive without
        // one). NOERRORUI so the app reports errors itself.
        .f_flags = win32.fof_allowundo | win32.fof_noconfirmation | win32.fof_wantnukewarning | win32.fof_noerrorui,
        .f_any_operations_aborted = 0,
        .h_name_mappings = null,
        .lpsz_progress_title = null,
    };
    const rc: u32 = @bitCast(win32.SHFileOperationW(&op));
    const still_exists = win32.GetFileAttributesW(wide.ptr) != win32.invalid_file_attributes;

    if (!still_exists) return .recycled;
    if (op.f_any_operations_aborted != 0) return .cancelled;
    if (rc == 0) return .{ .partial = 0 };
    return .{ .failed = rc };
}

/// Human-readable text for an error code from `moveToRecycleBin`.
pub fn describeError(code: u32) []const u8 {
    return switch (code) {
        0 => "some items could not be moved",
        2, 3, 0x7C => "the item no longer exists or the path is invalid",
        5, 0x78 => "access denied (it may be a protected system file, or need administrator rights)",
        32, 33 => "a file is in use by another program",
        0x75, 1223 => "the operation was cancelled",
        0x7E, 0x80 => "the destination is not available",
        8, 14 => "not enough memory",
        0x10000 => "an unspecified error occurred on the destination",
        else => "Windows reported an error",
    };
}

// --- internals -----------------------------------------------------------------

fn toWide(gpa: std.mem.Allocator, path: []const u8) OpenError![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => error.UnsupportedPath,
    };
}

fn openWithRaylib(gpa: std.mem.Allocator, path: []const u8) OpenError!void {
    // raylib passes the path to the shell inside single quotes and refuses
    // any path containing one.
    if (std.mem.indexOfScalar(u8, path, '\'') != null) return error.UnsupportedPath;
    const z = gpa.dupeZ(u8, path) catch return error.OutOfMemory;
    defer gpa.free(z);
    rl.openUrl(z.ptr);
}

/// ShellExecute may hand work to shell extensions that need COM, so the
/// calling thread must have COM initialized. Done once per thread.
threadlocal var com_initialized: bool = false;

fn ensureComOnThisThread() void {
    if (!is_windows or com_initialized) return;
    _ = win32.CoInitializeEx(null, win32.coinit_apartmentthreaded | win32.coinit_disable_ole1dde);
    com_initialized = true;
}

const win32 = struct {
    const sw_shownormal: c_int = 1;
    const fo_delete: c_uint = 3;
    const fof_noconfirmation: u16 = 0x0010;
    const fof_allowundo: u16 = 0x0040;
    const fof_noerrorui: u16 = 0x0400;
    const fof_wantnukewarning: u16 = 0x4000;
    const coinit_apartmentthreaded: u32 = 0x2;
    const coinit_disable_ole1dde: u32 = 0x4;
    const invalid_file_attributes: u32 = 0xFFFF_FFFF;
    const error_not_enough_memory: u32 = 8;
    const error_file_not_found: u32 = 2;

    const verb_open = std.unicode.utf8ToUtf16LeStringLiteral("open");
    const explorer_exe = std.unicode.utf8ToUtf16LeStringLiteral("explorer.exe");

    /// SHFILEOPSTRUCTW. Naturally aligned on 64-bit Windows (shellapi.h only
    /// packs it to 1 byte on 32-bit), which matches a Zig extern struct.
    const SHFILEOPSTRUCTW = extern struct {
        hwnd: ?*anyopaque,
        w_func: c_uint,
        p_from: [*]const u16,
        p_to: ?[*]const u16,
        f_flags: u16,
        f_any_operations_aborted: c_int,
        h_name_mappings: ?*anyopaque,
        lpsz_progress_title: ?[*:0]const u16,
    };

    comptime {
        if (is_windows and @sizeOf(usize) == 8) std.debug.assert(@sizeOf(SHFILEOPSTRUCTW) == 56);
    }

    extern "shell32" fn ShellExecuteW(
        hwnd: ?*anyopaque,
        operation: ?[*:0]const u16,
        file: [*:0]const u16,
        parameters: ?[*:0]const u16,
        directory: ?[*:0]const u16,
        show_cmd: c_int,
    ) callconv(.winapi) ?*anyopaque;

    extern "shell32" fn SHFileOperationW(op: *SHFILEOPSTRUCTW) callconv(.winapi) c_int;
    extern "kernel32" fn GetFileAttributesW(file_name: [*:0]const u16) callconv(.winapi) u32;
    extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) callconv(.winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
};

test "describeError covers common codes" {
    try std.testing.expect(std.mem.indexOf(u8, describeError(5), "access denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, describeError(32), "in use") != null);
    try std.testing.expectEqualStrings("Windows reported an error", describeError(0xDEAD));
}
