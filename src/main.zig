//! Disk Usage Analyzer — entry point.
//!
//! Opens a resizable window, builds the app, and runs the render loop. The
//! heavy work (scanning) happens on a background thread owned by the app, so
//! the UI stays responsive and fills in live as the scan progresses.

const std = @import("std");
const Io = std.Io;
const rl = @import("raylib.zig");
const ui = @import("ui.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    // One io instance for drive enumeration on the main thread. Each scan
    // spawns its own io on its worker thread.
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    rl.setConfigFlags(rl.flag_window_resizable | rl.flag_vsync_hint | rl.flag_msaa_4x_hint);
    rl.initWindow(1200, 760, "Disk Usage Analyzer");
    defer rl.closeWindow();
    rl.setWindowMinSize(880, 560);
    rl.setTargetFps(60);
    rl.setExitKey(rl.key_null); // don't close the window on ESC

    var app = try ui.App.init(gpa, io);
    defer app.deinit();

    while (!rl.windowShouldClose()) {
        app.frame();
    }
}
