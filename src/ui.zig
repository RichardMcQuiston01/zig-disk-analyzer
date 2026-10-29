//! Application UI: drive picker, list view, treemap view, settings dialog.
//!
//! The `App` owns the active scan and the navigation stack and renders one
//! frame at a time. While a scan runs, the tree keeps growing on the worker
//! thread; the UI reads it only through `Scan.snapshotChildren`, which returns
//! child pointers and their sizes captured together under the scan lock.
//!
//! All text goes through `Typography`, and every layout metric is scaled with
//! `s()`, so the font and text-size settings apply everywhere.

const std = @import("std");
const Io = std.Io;
const rl = @import("raylib.zig");
const model = @import("model.zig");
const treemap = @import("treemap.zig");
const scanner = @import("scanner.zig");
const drives = @import("drives.zig");
const format = @import("format.zig");
const settings_mod = @import("settings.zig");
const typography = @import("typography.zig");
const shell = @import("shell.zig");

const Node = model.Node;
const Rect = treemap.Rect;
const ChildSnapshot = scanner.ChildSnapshot;
const Settings = settings_mod.Settings;
const FontChoice = settings_mod.FontChoice;
const SizeChoice = settings_mod.SizeChoice;
const Typography = typography.Typography;

// --- theme -------------------------------------------------------------------

const col_bg = rl.rgb(24, 26, 31);
const col_panel = rl.rgb(31, 34, 40);
const col_panel_alt = rl.rgb(37, 41, 48);
const col_bar = rl.rgb(44, 48, 56);
const col_text = rl.rgb(226, 229, 234);
const col_text_dim = rl.rgb(150, 156, 166);
const col_accent = rl.rgb(94, 164, 255);
const col_border = rl.rgb(54, 59, 68);
const col_file = rl.rgb(96, 105, 119);
const col_tooltip = rl.rgb(16, 18, 22);
const col_overlay = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 150 };
const col_danger = rl.rgb(214, 69, 69);
const col_danger_hover = rl.rgb(232, 92, 92);
const col_error_text = rl.rgb(255, 135, 135);
const col_success_text = rl.rgb(129, 199, 132);

/// Directory tile colors. A tile's color comes from a hash of its name, so it
/// keeps its color while sizes (and therefore sort order) change mid-scan.
const palette = [_]rl.Color{
    rl.rgb(94, 164, 255),
    rl.rgb(255, 138, 101),
    rl.rgb(129, 199, 132),
    rl.rgb(186, 139, 245),
    rl.rgb(255, 202, 92),
    rl.rgb(100, 211, 204),
    rl.rgb(240, 113, 164),
    rl.rgb(159, 168, 218),
    rl.rgb(174, 213, 129),
    rl.rgb(255, 171, 145),
};

// Base sizes (at "Normal"); scaled at use sites.
const base_top_bar_h: f32 = 56;
const base_row_h: f32 = 26;
const base_list_header_h: f32 = 28;
const base_icon_w: f32 = 22;
const base_size_col_w: f32 = 110;
const base_pad: f32 = 10;

// Base text sizes.
const text_title: f32 = 34;
const text_heading: f32 = 22;
const text_subtitle: f32 = 18;
const text_body: f32 = 16;
const text_tile: f32 = 15;
const text_status: f32 = 14;
const text_small: f32 = 13;

const list_width_frac: f32 = 0.42;
const list_width_max: f32 = 560;

/// How often (seconds) the view re-reads the growing tree while scanning.
/// Re-sorting a large folder every frame would waste CPU the scan could use.
const live_refresh_interval: f64 = 0.25;

/// Sample text for the settings preview (includes accented and non-Latin
/// letters, which only render with a TTF font).
const preview_text = "The quick brown fox - Caf\u{00E9}, \u{00D1}and\u{00FA}, \u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}  1.4 GB";

/// When false, the screen behind a modal ignores hover and clicks.
var input_enabled: bool = true;

fn clicked() bool {
    return input_enabled and rl.mousePressedLeft();
}

fn hovering(r: rl.Rectangle) bool {
    return input_enabled and rl.pointInRect(rl.mousePosition(), r);
}

fn wheel() f32 {
    return if (input_enabled) rl.mouseWheel() else 0;
}

fn rightClicked() bool {
    return input_enabled and rl.mousePressedRight();
}

const Mode = enum { picker, browsing };

/// Which (if any) layer is on top of the main screen and owns input.
const Overlay = enum { none, menu, confirm, deleting, settings };

/// The right-click menu: what was clicked and where to draw the menu.
const MenuState = struct {
    target: ChildSnapshot,
    x: f32,
    y: f32,
};

/// A pending "Move to Recycle Bin?" confirmation. Owns `path`.
const ConfirmState = struct {
    target: ChildSnapshot,
    path: []u8,
};

/// A Recycle Bin operation running on its own thread, so the window keeps
/// redrawing while Windows works (and shows its own progress or prompts).
const DeleteJob = struct {
    gpa: std.mem.Allocator,
    target: ChildSnapshot,
    path: []u8,
    owner: ?*anyopaque,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    outcome: shell.RecycleOutcome = .unsupported,

    fn run(job: *DeleteJob) void {
        job.outcome = shell.moveToRecycleBin(job.gpa, job.path, job.owner);
        job.done.store(true, .release);
    }
};

const NoticeKind = enum { success, info, failure };

/// A two-line message shown at the bottom of the window for a few seconds.
const Notice = struct {
    kind: NoticeKind,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    detail_buf: [256]u8 = undefined,
    detail_len: usize = 0,
    until: f64,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    roots_arena: std.heap.ArenaAllocator,
    roots: []drives.Root,

    settings: Settings,
    typo: Typography,
    settings_open: bool = false,

    scan: ?*scanner.Scan = null,
    mode: Mode = .picker,

    nav: std.ArrayList(*Node) = .empty,

    /// Sorted snapshot of the current folder's children and their sizes.
    view_cache: std.ArrayList(ChildSnapshot) = .empty,
    cache_owner: ?*Node = null,
    /// Size of the current folder, captured with `view_cache`.
    cache_parent_size: u64 = 0,
    /// True once the snapshot was taken after the scan stopped, so it is final.
    cache_is_final: bool = false,
    last_refresh: f64 = 0,

    // Treemap scratch (rebuilt each frame).
    tm_entries: std.ArrayList(ChildSnapshot) = .empty,
    tm_sizes: std.ArrayList(u64) = .empty,
    tm_rects: std.ArrayList(Rect) = .empty,

    list_scroll: f32 = 0,

    menu: ?MenuState = null,
    confirm: ?ConfirmState = null,
    delete_job: ?*DeleteJob = null,
    notice: ?Notice = null,

    /// Call after the window exists (fonts need a GL context).
    pub fn init(gpa: std.mem.Allocator, io: Io) !App {
        var roots_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer roots_arena.deinit();
        const roots = try drives.enumerate(roots_arena.allocator(), io);
        const loaded = loadSettings();
        return .{
            .gpa = gpa,
            .io = io,
            .roots_arena = roots_arena,
            .roots = roots,
            .settings = loaded,
            .typo = Typography.init(loaded),
        };
    }

    /// Call before the window closes (fonts live in GPU memory).
    pub fn deinit(self: *App) void {
        // A Recycle Bin operation can't be interrupted; wait for it so it
        // doesn't outlive the data it points at.
        if (self.delete_job) |job| {
            job.thread.join();
            self.gpa.free(job.path);
            self.gpa.destroy(job);
            self.delete_job = null;
        }
        self.closeConfirm();
        if (self.scan) |active| active.deinit();
        self.typo.deinit();
        self.nav.deinit(self.gpa);
        self.view_cache.deinit(self.gpa);
        self.tm_entries.deinit(self.gpa);
        self.tm_sizes.deinit(self.gpa);
        self.tm_rects.deinit(self.gpa);
        self.roots_arena.deinit();
    }

    /// Scale a layout metric by the text-size setting.
    fn s(self: *const App, value: f32) f32 {
        return self.typo.s(value);
    }

    fn current(self: *App) ?*Node {
        if (self.nav.items.len == 0) return null;
        return self.nav.items[self.nav.items.len - 1];
    }

    fn startScan(self: *App, path: []const u8) !void {
        // `path` may point into the old scan's arena (e.g. a rescan passes the
        // old root's name), so copy it out before freeing that scan.
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = @min(path.len, path_buf.len);
        @memcpy(path_buf[0..n], path[0..n]);
        const safe_path = path_buf[0..n];

        if (self.scan) |old| {
            old.deinit();
            self.scan = null;
        }
        // Drop references into the now-freed arena before any draw can read them.
        self.menu = null;
        self.closeConfirm();
        self.view_cache.clearRetainingCapacity();
        self.invalidateCache();

        const new_scan = try scanner.Scan.start(self.gpa, safe_path);
        self.scan = new_scan;
        self.nav.clearRetainingCapacity();
        try self.nav.append(self.gpa, new_scan.root);
        self.list_scroll = 0;
        self.mode = .browsing;
    }

    fn invalidateCache(self: *App) void {
        self.cache_owner = null;
        self.cache_parent_size = 0;
        self.cache_is_final = false;
    }

    fn navTo(self: *App, node: *Node) void {
        self.nav.append(self.gpa, node) catch return;
        self.invalidateCache();
        self.list_scroll = 0;
    }

    fn navToIndex(self: *App, index: usize) void {
        if (index + 1 >= self.nav.items.len) return;
        self.nav.shrinkRetainingCapacity(index + 1);
        self.invalidateCache();
        self.list_scroll = 0;
    }

    fn navUp(self: *App) void {
        if (self.nav.items.len > 1) {
            _ = self.nav.pop();
            self.invalidateCache();
            self.list_scroll = 0;
        }
    }

    /// Re-read the current folder from the (possibly still growing) tree.
    /// Immediately after navigation; then a few times per second while the
    /// scan runs; then once more after it stops; then never.
    fn refreshCache(self: *App) void {
        const node = self.current() orelse return;
        const active = self.scan orelse return;
        const scanning = active.isScanning();
        const now = rl.time();

        if (self.cache_owner == node) {
            if (self.cache_is_final) return;
            if (scanning and now - self.last_refresh < live_refresh_interval) return;
        }

        self.cache_parent_size = active.snapshotChildren(node, &self.view_cache, self.gpa) catch return;
        std.mem.sort(ChildSnapshot, self.view_cache.items, {}, cmpSizeDesc);
        self.cache_owner = node;
        self.cache_is_final = !scanning;
        self.last_refresh = now;
    }

    pub fn frame(self: *App) void {
        rl.beginDrawing();
        rl.clearBackground(col_bg);

        self.pollDeleteJob();

        // An overlay that opens during this frame must not also react to the
        // click that opened it (e.g. read it as "clicked outside, close").
        // So each layer only takes input if it was already on top when the
        // frame started.
        const top_at_start = self.overlay();

        input_enabled = top_at_start == .none;
        switch (self.mode) {
            .picker => self.drawPicker(),
            .browsing => self.drawBrowser(),
        }

        const top_now = self.overlay();
        input_enabled = top_now == top_at_start;
        switch (top_now) {
            .none => {},
            .menu => self.drawMenu(),
            .confirm => self.drawConfirm(),
            .deleting => self.drawDeleting(),
            .settings => self.drawSettings(),
        }
        input_enabled = true;

        self.drawNotice();
        rl.endDrawing();
    }

    fn overlay(self: *const App) Overlay {
        if (self.delete_job != null) return .deleting;
        if (self.confirm != null) return .confirm;
        if (self.settings_open) return .settings;
        if (self.menu != null) return .menu;
        return .none;
    }

    fn applySettings(self: *App, new: Settings) void {
        self.typo.setFont(new.font);
        self.typo.setSize(new.size);
        self.settings = new;
        saveSettings(new);
    }

    // --- picker --------------------------------------------------------------

    fn drawPicker(self: *App) void {
        const sw: f32 = @floatFromInt(rl.screenWidth());
        const margin = self.s(30);

        self.typo.draw("Disk Usage Analyzer", margin, self.s(36), text_title, col_text);
        self.typo.draw("Choose a drive or volume to scan", margin, self.s(36) + self.typo.pxF(text_title) + self.s(10), text_subtitle, col_text_dim);

        var right = sw - margin;
        if (self.button(&right, self.s(36), "Settings")) self.settings_open = true;

        const btn_w = self.s(260);
        const btn_h = self.s(64);
        const gap = self.s(16);
        const cols: usize = @max(1, @as(usize, @intFromFloat((sw - margin * 2 + gap) / (btn_w + gap))));
        const start_y = self.s(150);

        for (self.roots, 0..) |root_entry, i| {
            const cx = margin + @as(f32, @floatFromInt(i % cols)) * (btn_w + gap);
            const cy = start_y + @as(f32, @floatFromInt(i / cols)) * (btn_h + gap);
            const r = rl.Rectangle{ .x = cx, .y = cy, .width = btn_w, .height = btn_h };
            if (self.drawDriveButton(r, root_entry)) {
                self.startScan(root_entry.path) catch {};
            }
        }

        if (self.roots.len == 0) {
            self.typo.draw("No drives found.", margin, start_y, text_heading, col_text_dim);
        }
    }

    fn drawDriveButton(self: *App, r: rl.Rectangle, root_entry: drives.Root) bool {
        const hovered = hovering(r);
        rl.drawRectangleRounded(r, 0.18, 8, if (hovered) col_panel_alt else col_panel);
        rl.drawRectangleLines(r, if (hovered) 2 else 1, if (hovered) col_accent else col_border);

        var buf: [256]u8 = undefined;
        const label = self.typo.fit(&buf, root_entry.label, r.width - self.s(36), 24);
        self.typo.draw(label, r.x + self.s(18), r.y + self.s(10), 24, col_text);
        self.typo.draw("Scan >", r.x + self.s(18), r.y + r.height - self.s(10) - self.typo.pxF(text_tile), text_tile, col_text_dim);
        return hovered and clicked();
    }

    // --- browser -------------------------------------------------------------

    fn drawBrowser(self: *App) void {
        self.refreshCache();

        const sw: f32 = @floatFromInt(rl.screenWidth());
        const sh: f32 = @floatFromInt(rl.screenHeight());
        const top_bar_h = self.s(base_top_bar_h);

        self.drawTopBar(sw);

        var list_w = sw * list_width_frac;
        if (list_w > list_width_max * self.typo.factor()) list_w = list_width_max * self.typo.factor();
        list_w = @min(list_w, sw * 0.6);

        const list_area = rl.Rectangle{ .x = 0, .y = top_bar_h, .width = list_w, .height = sh - top_bar_h };
        const map_area = rl.Rectangle{ .x = list_w, .y = top_bar_h, .width = sw - list_w, .height = sh - top_bar_h };

        self.drawList(list_area);
        self.drawTreemap(map_area);
    }

    fn drawTopBar(self: *App, sw: f32) void {
        const top_bar_h = self.s(base_top_bar_h);
        rl.drawRectangle(0, 0, @intFromFloat(sw), @intFromFloat(top_bar_h), col_panel);
        rl.drawLine(.{ .x = 0, .y = top_bar_h }, .{ .x = sw, .y = top_bar_h }, 1, col_border);

        // Right-aligned action buttons, vertically centered in the bar.
        const btn_h = self.typo.pxF(text_body) + self.s(16);
        const btn_y = (top_bar_h - btn_h) / 2;
        var x = sw - self.s(base_pad);
        const change = self.button(&x, btn_y, "Change Drive");
        const rescan = self.button(&x, btn_y, "Rescan");
        const up = self.button(&x, btn_y, "Up");
        const open_settings = self.button(&x, btn_y, "Settings");

        if (open_settings) self.settings_open = true;
        if (change) {
            self.mode = .picker;
            return;
        }
        if (rescan) {
            if (self.nav.items.len > 0) {
                const path = self.nav.items[0].name;
                self.startScan(path) catch {};
            }
            return;
        }
        if (up) self.navUp();

        self.drawBreadcrumb(self.s(base_pad), x - self.s(20));
    }

    /// A right-anchored button at height `y`, advancing `*right` leftward.
    /// Returns true when clicked.
    fn button(self: *App, right: *f32, y: f32, label: [*:0]const u8) bool {
        return self.styledButton(right, y, label, .normal);
    }

    const ButtonStyle = enum { normal, danger };

    fn styledButton(self: *App, right: *f32, y: f32, label: [*:0]const u8, style: ButtonStyle) bool {
        const h = self.typo.pxF(text_body) + self.s(16);
        const w = self.typo.measure(label, text_body) + self.s(24);
        const r = rl.Rectangle{ .x = right.* - w, .y = y, .width = w, .height = h };
        right.* = r.x - self.s(8);

        const hovered = hovering(r);
        switch (style) {
            .normal => {
                rl.drawRectangleRounded(r, 0.25, 6, if (hovered) col_panel_alt else col_bar);
                rl.drawRectangleLines(r, 1, if (hovered) col_accent else col_border);
            },
            .danger => rl.drawRectangleRounded(r, 0.25, 6, if (hovered) col_danger_hover else col_danger),
        }
        self.typo.drawCentered(label, r.x + self.s(12), r.y, r.height, text_body, col_text);
        return hovered and clicked();
    }

    fn drawBreadcrumb(self: *App, left: f32, right_limit: f32) void {
        var x = left;
        const crumb_h = self.typo.pxF(text_body) + self.s(6);
        const y = self.s(6);
        var buf: [256]u8 = undefined;

        for (self.nav.items, 0..) |node, i| {
            const remaining = right_limit - x;
            if (remaining < self.s(40)) break;
            const label = self.typo.fit(&buf, node.name, remaining, text_body);
            const w = self.typo.measure(label, text_body);
            const r = rl.Rectangle{ .x = x, .y = y, .width = w + self.s(8), .height = crumb_h };
            const is_last = i == self.nav.items.len - 1;
            self.typo.drawCentered(label, x + self.s(4), y, crumb_h, text_body, if (is_last) col_text else col_accent);
            if (!is_last and hovering(r) and clicked()) self.navToIndex(i);
            x += w + self.s(8);
            if (!is_last) {
                self.typo.drawCentered(">", x + self.s(2), y, crumb_h, text_body, col_text_dim);
                x += self.typo.measure(">", text_body) + self.s(8);
            }
        }

        // Progress / summary under the breadcrumb.
        var pbuf: [160]u8 = undefined;
        const line = self.statusLine(&pbuf);
        self.typo.draw(line, left + self.s(4), y + crumb_h + self.s(2), text_status, col_text_dim);
    }

    fn statusLine(self: *App, buf: []u8) [:0]const u8 {
        const active = self.scan orelse return toZ(buf, "");
        var size_buf: [32]u8 = undefined;
        const size_str = format.bytes(&size_buf, active.rootSize());
        return switch (active.phase()) {
            .scanning => printZ(buf, "Scanning...   {d} items  |  {s}", .{ active.itemsScanned(), size_str }),
            .done => printZ(buf, "Done   {d} items  |  {s} total", .{ active.itemsScanned(), size_str }),
            .cancelled => toZ(buf, "Scan cancelled"),
            .failed => toZ(buf, "Could not open this drive"),
            .idle => toZ(buf, ""),
        };
    }

    // --- list view -----------------------------------------------------------

    fn drawList(self: *App, area: rl.Rectangle) void {
        const pad = self.s(base_pad);
        const row_h = self.s(base_row_h);
        const header_h = self.s(base_list_header_h);
        const icon_w = self.s(base_icon_w);
        const size_col_w = self.s(base_size_col_w);

        rl.drawRectangleRec(area, col_panel);
        rl.drawLine(
            .{ .x = area.x + area.width, .y = area.y },
            .{ .x = area.x + area.width, .y = area.y + area.height },
            1,
            col_border,
        );

        const right_edge = area.x + area.width - pad;
        self.typo.drawCentered("NAME", area.x + pad + icon_w, area.y, header_h, text_small, col_text_dim);
        self.typo.drawCentered("SIZE", right_edge - self.typo.measure("SIZE", text_small), area.y, header_h, text_small, col_text_dim);

        const list_top = area.y + header_h;
        const view_h = area.height - header_h;
        const entries = self.view_cache.items;

        // Scrolling.
        const content_h = @as(f32, @floatFromInt(entries.len)) * row_h;
        const max_scroll = @max(0, content_h - view_h);
        if (hovering(area)) self.list_scroll -= wheel() * row_h * 3;
        self.list_scroll = std.math.clamp(self.list_scroll, 0, max_scroll);

        rl.beginScissor(
            @intFromFloat(area.x),
            @intFromFloat(list_top),
            @intFromFloat(area.width),
            @intFromFloat(@max(0, view_h)),
        );
        defer rl.endScissor();

        const mouse = rl.mousePosition();
        const name_x = area.x + pad + icon_w;
        const name_max_w = right_edge - size_col_w - name_x;
        var to_open: ?*Node = null;

        for (entries, 0..) |entry, i| {
            const ry = list_top - self.list_scroll + @as(f32, @floatFromInt(i)) * row_h;
            if (ry + row_h < list_top or ry > area.y + area.height) continue;
            const node = entry.node;

            const row = rl.Rectangle{ .x = area.x, .y = ry, .width = area.width, .height = row_h };
            const hovered = hovering(row) and mouse.y >= list_top;
            if (hovered) {
                rl.drawRectangleRec(row, col_panel_alt);
                if (node.is_dir and clicked()) to_open = node;
                if (rightClicked()) self.openMenu(entry);
            } else if (i % 2 == 1) {
                rl.drawRectangleRec(row, col_panel_alt);
            }

            // Proportional bar under the name.
            const frac = model.fractionOf(entry.size, self.cache_parent_size);
            const bar_w: f32 = @floatCast(frac * @max(0, name_max_w));
            rl.drawRectangleRec(
                .{ .x = name_x, .y = ry + row_h - self.s(4), .width = bar_w, .height = @max(1, self.s(2)) },
                if (node.is_dir) col_accent else col_file,
            );

            const icon_y = ry + (row_h - self.s(14)) / 2;
            if (node.is_dir) self.drawFolderIcon(area.x + pad, icon_y) else self.drawFileIcon(area.x + pad, icon_y);

            var name_buf: [512]u8 = undefined;
            const name = self.typo.fit(&name_buf, node.name, name_max_w, text_body);
            self.typo.drawCentered(name, name_x, ry, row_h, text_body, if (node.is_dir) col_text else col_text_dim);

            var size_buf: [32]u8 = undefined;
            const size_str = format.bytesZ(&size_buf, entry.size);
            const size_w = self.typo.measure(size_str, text_body);
            self.typo.drawCentered(size_str, right_edge - size_w, ry, row_h, text_body, col_text);
        }

        if (entries.len == 0) {
            const scanning = if (self.scan) |active| active.isScanning() else false;
            const msg: [*:0]const u8 = if (scanning) "Scanning..." else "(empty)";
            self.typo.draw(msg, area.x + pad, list_top + pad, text_body, col_text_dim);
        }

        // Navigate after the loop so the snapshot isn't swapped mid-iteration.
        if (to_open) |node| self.navTo(node);
    }

    // --- treemap view --------------------------------------------------------

    fn drawTreemap(self: *App, area: rl.Rectangle) void {
        const pad = self.s(base_pad);
        const inner = rl.Rectangle{
            .x = area.x + pad,
            .y = area.y + pad,
            .width = area.width - pad * 2,
            .height = area.height - pad * 2,
        };

        // Positive-size children only (the cache is sorted desc, zeros trail).
        self.tm_entries.clearRetainingCapacity();
        self.tm_sizes.clearRetainingCapacity();
        for (self.view_cache.items) |entry| {
            if (entry.size == 0) continue;
            self.tm_entries.append(self.gpa, entry) catch break;
            self.tm_sizes.append(self.gpa, entry.size) catch break;
        }
        self.tm_rects.resize(self.gpa, self.tm_sizes.items.len) catch return;

        if (self.tm_sizes.items.len == 0) {
            const scanning = if (self.scan) |active| active.isScanning() else false;
            const msg: [*:0]const u8 = if (scanning) "Waiting for data..." else "No data to display";
            self.typo.draw(msg, inner.x, inner.y, text_body, col_text_dim);
            return;
        }

        treemap.squarify(
            self.tm_sizes.items,
            .{ .x = inner.x, .y = inner.y, .w = inner.width, .h = inner.height },
            self.tm_rects.items,
        );

        const mouse = rl.mousePosition();
        var hovered: ?ChildSnapshot = null;
        var hovered_rect: rl.Rectangle = undefined;

        // A tile shows a label only if both lines fit.
        const label_pad = self.s(6);
        const name_h = self.typo.pxF(text_tile);
        const size_h = self.typo.pxF(text_small);
        const min_label_h = label_pad + name_h + self.s(3) + size_h + self.s(4);
        const min_label_w = self.s(60);

        for (self.tm_entries.items, self.tm_rects.items) |entry, cell| {
            const r = rl.Rectangle{ .x = cell.x, .y = cell.y, .width = cell.w, .height = cell.h };
            if (r.width < 1 or r.height < 1) continue;
            const node = entry.node;

            rl.drawRectangleRec(r, if (node.is_dir) colorFor(node.name) else col_file);
            rl.drawRectangleLines(r, 1, col_bg);

            if (r.width > min_label_w and r.height > min_label_h) {
                var name_buf: [512]u8 = undefined;
                const name = self.typo.fit(&name_buf, node.name, r.width - label_pad * 2, text_tile);
                self.typo.draw(name, r.x + label_pad, r.y + label_pad, text_tile, col_bg);
                var size_buf: [32]u8 = undefined;
                const size_str = format.bytesZ(&size_buf, entry.size);
                self.typo.draw(size_str, r.x + label_pad, r.y + label_pad + name_h + self.s(3), text_small, rl.fade(col_bg, 0.75));
            }

            if (hovering(r)) {
                hovered = entry;
                hovered_rect = r;
            }
        }

        if (hovered) |entry| {
            rl.drawRectangleLines(hovered_rect, 2, col_text);
            if (rightClicked()) {
                self.openMenu(entry);
            } else {
                self.drawTooltip(entry, mouse, area);
                if (entry.node.is_dir and clicked()) self.navTo(entry.node);
            }
        }
    }

    fn drawTooltip(self: *App, entry: ChildSnapshot, mouse: rl.Vector2, bounds: rl.Rectangle) void {
        var name_buf: [512]u8 = undefined;
        const name = self.typo.fit(&name_buf, entry.node.name, bounds.width * 0.8, text_tile);
        var size_buf: [32]u8 = undefined;
        const size_str = format.bytesZ(&size_buf, entry.size);

        const inner_pad = self.s(10);
        const line_gap = self.s(4);
        const tw = @max(self.typo.measure(name, text_tile), self.typo.measure(size_str, text_status)) + inner_pad * 2;
        const th = inner_pad * 2 + self.typo.pxF(text_tile) + line_gap + self.typo.pxF(text_status);
        var tx = mouse.x + self.s(16);
        var ty = mouse.y + self.s(16);
        if (tx + tw > bounds.x + bounds.width) tx = mouse.x - tw - self.s(8);
        if (ty + th > bounds.y + bounds.height) ty = mouse.y - th - self.s(8);

        const r = rl.Rectangle{ .x = tx, .y = ty, .width = tw, .height = th };
        rl.drawRectangleRec(r, col_tooltip);
        rl.drawRectangleLines(r, 1, col_border);
        self.typo.draw(name, tx + inner_pad, ty + inner_pad, text_tile, col_text);
        self.typo.draw(size_str, tx + inner_pad, ty + inner_pad + self.typo.pxF(text_tile) + line_gap, text_status, col_accent);
    }

    /// A small folder glyph: a tab on top of a body, in the accent color.
    fn drawFolderIcon(self: *App, x: f32, y: f32) void {
        rl.drawRectangleRec(.{ .x = x, .y = y, .width = self.s(7), .height = self.s(3) }, col_accent);
        rl.drawRectangleRec(.{ .x = x, .y = y + self.s(2), .width = self.s(16), .height = self.s(11) }, col_accent);
    }

    /// A small file glyph: an outlined page.
    fn drawFileIcon(self: *App, x: f32, y: f32) void {
        rl.drawRectangleLines(.{ .x = x + self.s(2), .y = y - self.s(1), .width = self.s(11), .height = self.s(15) }, 1, col_file);
    }

    // --- right-click menu ----------------------------------------------------

    fn openMenu(self: *App, target: ChildSnapshot) void {
        const mouse = rl.mousePosition();
        self.menu = .{ .target = target, .x = mouse.x, .y = mouse.y };
    }

    const MenuAction = enum { open, delete };

    fn drawMenu(self: *App) void {
        const m = self.menu orelse return;
        const node = m.target.node;
        const sw: f32 = @floatFromInt(rl.screenWidth());
        const sh: f32 = @floatFromInt(rl.screenHeight());

        const scanning = if (self.scan) |active| active.isScanning() else false;
        const can_delete = shell.recycleSupported() and !scanning;
        const open_label: [:0]const u8 = if (node.is_dir) "Open Folder" else "Open Containing Folder";
        const delete_label: [:0]const u8 = if (!shell.recycleSupported())
            "Delete (Windows only)"
        else if (scanning)
            "Delete (after the scan finishes)"
        else
            "Delete (to Recycle Bin)";

        const Item = struct { label: [:0]const u8, enabled: bool, action: MenuAction };
        const items = [_]Item{
            .{ .label = open_label, .enabled = true, .action = .open },
            .{ .label = delete_label, .enabled = can_delete, .action = .delete },
        };

        const pad_x = self.s(12);
        const item_h = self.typo.pxF(text_body) + self.s(12);
        const header_h = self.typo.pxF(text_small) + self.s(14);
        var w = self.s(200);
        for (items) |item| w = @max(w, self.typo.measure(item.label, text_body) + pad_x * 2);
        w = @min(w, @min(self.s(380), sw - 8));
        const h = header_h + item_h * @as(f32, @floatFromInt(items.len)) + self.s(6);

        // Open at the cursor, but keep the whole menu on screen.
        const x = std.math.clamp(m.x, 4, @max(4, sw - w - 4));
        const y = std.math.clamp(m.y, 4, @max(4, sh - h - 4));
        const panel = rl.Rectangle{ .x = x, .y = y, .width = w, .height = h };

        rl.drawRectangleRounded(panel, 0.06, 6, col_tooltip);
        rl.drawRectangleLines(panel, 1, col_border);

        // Header: which item the menu is for.
        var name_buf: [512]u8 = undefined;
        const name = self.typo.fit(&name_buf, node.name, w - pad_x * 2, text_small);
        self.typo.drawCentered(name, x + pad_x, y, header_h, text_small, col_text_dim);
        rl.drawLine(.{ .x = x + 1, .y = y + header_h }, .{ .x = x + w - 1, .y = y + header_h }, 1, col_border);

        var chosen: ?MenuAction = null;
        var iy = y + header_h + self.s(3);
        for (items) |item| {
            const r = rl.Rectangle{ .x = x + self.s(3), .y = iy, .width = w - self.s(6), .height = item_h };
            const hovered = item.enabled and hovering(r);
            if (hovered) rl.drawRectangleRounded(r, 0.2, 4, col_panel_alt);
            var label_buf: [128]u8 = undefined;
            const label = self.typo.fit(&label_buf, item.label, w - pad_x * 2, text_body);
            self.typo.drawCentered(label, x + pad_x, iy, item_h, text_body, if (item.enabled) col_text else rl.fade(col_text_dim, 0.7));
            if (hovered and clicked()) chosen = item.action;
            iy += item_h;
        }

        if (chosen) |action| {
            self.menu = null;
            switch (action) {
                .open => self.runOpen(m.target),
                .delete => self.askDelete(m.target),
            }
            return;
        }

        // Click (either button) outside, or Escape, closes the menu.
        const outside_click = input_enabled and (rl.mousePressedLeft() or rl.mousePressedRight()) and
            !rl.pointInRect(rl.mousePosition(), panel);
        const escape = input_enabled and rl.keyPressed(rl.key_escape);
        if (outside_click or escape) self.menu = null;
    }

    fn runOpen(self: *App, target: ChildSnapshot) void {
        const node = target.node;
        const path = scanner.buildPathAlloc(self.gpa, node) catch {
            self.notify(.failure, "Couldn't open \"{s}\"", .{node.name}, "Out of memory.", .{});
            return;
        };
        defer self.gpa.free(path);

        const result = if (node.is_dir) shell.openFolder(self.gpa, path) else shell.revealInFolder(self.gpa, path);
        result catch |err| {
            const reason: []const u8 = switch (err) {
                error.OpenFailed => "The system couldn't open this location. It may have been moved or deleted.",
                error.UnsupportedPath => "The path contains characters the system file opener can't handle.",
                error.OutOfMemory => "Out of memory.",
            };
            self.notify(.failure, "Couldn't open \"{s}\"", .{node.name}, "{s}", .{reason});
        };
    }

    // --- delete: confirm, run, report ----------------------------------------

    fn askDelete(self: *App, target: ChildSnapshot) void {
        const path = scanner.buildPathAlloc(self.gpa, target.node) catch {
            self.notify(.failure, "Couldn't prepare the delete", .{}, "Out of memory.", .{});
            return;
        };
        self.closeConfirm();
        self.confirm = .{ .target = target, .path = path };
    }

    fn closeConfirm(self: *App) void {
        if (self.confirm) |c| self.gpa.free(c.path);
        self.confirm = null;
    }

    fn drawConfirm(self: *App) void {
        const c = self.confirm orelse return;
        const node = c.target.node;
        const sw: f32 = @floatFromInt(rl.screenWidth());
        const sh: f32 = @floatFromInt(rl.screenHeight());
        rl.drawRectangle(0, 0, @intFromFloat(sw), @intFromFloat(sh), col_overlay);

        const pad = self.s(20);
        const gap = self.s(6);
        const btn_h = self.typo.pxF(text_body) + self.s(16);
        const panel_w = @min(sw - self.s(40), self.s(560));
        const content_w = panel_w - pad * 2;
        const panel_h = pad + self.typo.pxF(text_heading) + self.s(14) +
            self.typo.pxF(text_body) + gap + self.typo.pxF(text_status) + gap + self.typo.pxF(text_small) +
            self.s(16) + (self.typo.pxF(text_small) + self.s(3)) * 2 + self.s(18) + btn_h + pad;
        const panel = rl.Rectangle{
            .x = @round((sw - panel_w) / 2),
            .y = @round(@max(self.s(10), (sh - panel_h) / 2)),
            .width = panel_w,
            .height = panel_h,
        };
        rl.drawRectangleRounded(panel, 0.04, 8, col_panel);
        rl.drawRectangleLines(panel, 1, col_border);

        const x = panel.x + pad;
        var y = panel.y + pad;
        self.typo.draw("Move to Recycle Bin?", x, y, text_heading, col_text);
        y += self.typo.pxF(text_heading) + self.s(14);

        var buf: [512]u8 = undefined;
        self.typo.draw(self.typo.fit(&buf, node.name, content_w, text_body), x, y, text_body, col_text);
        y += self.typo.pxF(text_body) + gap;

        var size_buf: [32]u8 = undefined;
        var line_buf: [96]u8 = undefined;
        const kind_line = printZ(&line_buf, "{s}  |  {s}", .{
            if (node.is_dir) "Folder" else "File",
            format.bytes(&size_buf, c.target.size),
        });
        self.typo.draw(kind_line, x, y, text_status, col_text_dim);
        y += self.typo.pxF(text_status) + gap;

        self.typo.draw(self.typo.fit(&buf, c.path, content_w, text_small), x, y, text_small, col_text_dim);
        y += self.typo.pxF(text_small) + self.s(16);

        self.typo.draw("Space is freed when the Recycle Bin is emptied.", x, y, text_small, col_text_dim);
        y += self.typo.pxF(text_small) + self.s(3);
        self.typo.draw(
            self.typo.fit(&buf, "If it can't be recycled, Windows asks before deleting it permanently.", content_w, text_small),
            x,
            y,
            text_small,
            col_text_dim,
        );
        y += self.typo.pxF(text_small) + self.s(3) + self.s(18);

        var right = panel.x + panel.width - pad;
        const confirmed = self.styledButton(&right, y, "Move to Recycle Bin", .danger);
        const cancelled = self.button(&right, y, "Cancel");
        const outside_click = clicked() and !rl.pointInRect(rl.mousePosition(), panel);
        const escape = input_enabled and rl.keyPressed(rl.key_escape);

        if (confirmed) {
            const pending = self.confirm.?;
            self.confirm = null; // the job takes ownership of `pending.path`
            self.startDelete(pending);
        } else if (cancelled or outside_click or escape) {
            self.closeConfirm();
        }
    }

    fn startDelete(self: *App, pending: ConfirmState) void {
        const job = self.gpa.create(DeleteJob) catch {
            self.gpa.free(pending.path);
            self.notify(.failure, "Couldn't start the delete", .{}, "Out of memory.", .{});
            return;
        };
        job.* = .{
            .gpa = self.gpa,
            .target = pending.target,
            .path = pending.path,
            .owner = rl.windowHandle(),
        };
        job.thread = std.Thread.spawn(.{}, DeleteJob.run, .{job}) catch {
            self.gpa.free(job.path);
            self.gpa.destroy(job);
            self.notify(.failure, "Couldn't start the delete", .{}, "The system refused to start a worker thread.", .{});
            return;
        };
        self.delete_job = job;
    }

    /// Finish a delete once its thread reports done: update the tree only if
    /// the item is verifiably gone, and tell the user what happened.
    fn pollDeleteJob(self: *App) void {
        const job = self.delete_job orelse return;
        if (!job.done.load(.acquire)) return;
        job.thread.join();
        self.delete_job = null;
        defer {
            self.gpa.free(job.path);
            self.gpa.destroy(job);
        }

        const name = job.target.node.name;
        var size_buf: [32]u8 = undefined;
        const size_str = format.bytes(&size_buf, job.target.size);

        switch (job.outcome) {
            .recycled => {
                if (self.scan) |active| _ = active.removeNode(job.target.node);
                self.invalidateCache();
                self.notify(
                    .success,
                    "Moved \"{s}\" to the Recycle Bin",
                    .{name},
                    "{s} will be freed when the Recycle Bin is emptied.",
                    .{size_str},
                );
            },
            .cancelled => self.notify(.info, "Nothing was deleted", .{}, "\"{s}\" was left where it was.", .{name}),
            .partial => self.notify(
                .failure,
                "Some items in \"{s}\" couldn't be moved",
                .{name},
                "Rescan to see what's left and refresh the sizes.",
                .{},
            ),
            .failed => |code| self.notify(
                .failure,
                "Couldn't move \"{s}\" to the Recycle Bin",
                .{name},
                "Reason: {s} (code {d}).",
                .{ shell.describeError(code), code },
            ),
            .unsupported => self.notify(.failure, "Delete isn't supported on this system", .{}, "Only Windows is supported for now.", .{}),
        }
    }

    fn drawDeleting(self: *App) void {
        const job = self.delete_job orelse return;
        const sw: f32 = @floatFromInt(rl.screenWidth());
        const sh: f32 = @floatFromInt(rl.screenHeight());
        rl.drawRectangle(0, 0, @intFromFloat(sw), @intFromFloat(sh), col_overlay);

        const pad = self.s(20);
        const panel_w = @min(sw - self.s(40), self.s(480));
        const panel_h = pad * 2 + self.typo.pxF(text_subtitle) + self.s(10) + self.typo.pxF(text_body) + self.s(8) + self.typo.pxF(text_small);
        const panel = rl.Rectangle{ .x = @round((sw - panel_w) / 2), .y = @round((sh - panel_h) / 2), .width = panel_w, .height = panel_h };
        rl.drawRectangleRounded(panel, 0.05, 8, col_panel);
        rl.drawRectangleLines(panel, 1, col_border);

        // Animated dots so it's clear the app hasn't frozen.
        const dots: usize = @intFromFloat(@mod(rl.time() * 2.5, 4.0));
        var title_buf: [64]u8 = undefined;
        const title = printZ(&title_buf, "Moving to the Recycle Bin{s}", .{"..."[0..dots]});

        var y = panel.y + pad;
        self.typo.draw(title, panel.x + pad, y, text_subtitle, col_text);
        y += self.typo.pxF(text_subtitle) + self.s(10);
        var buf: [512]u8 = undefined;
        self.typo.draw(self.typo.fit(&buf, job.target.node.name, panel_w - pad * 2, text_body), panel.x + pad, y, text_body, col_text_dim);
        y += self.typo.pxF(text_body) + self.s(8);
        self.typo.draw("Windows may show its own progress window or a question.", panel.x + pad, y, text_small, col_text_dim);
    }

    // --- notices -------------------------------------------------------------

    fn notify(
        self: *App,
        kind: NoticeKind,
        comptime title_fmt: []const u8,
        title_args: anytype,
        comptime detail_fmt: []const u8,
        detail_args: anytype,
    ) void {
        var n = Notice{ .kind = kind, .until = rl.time() + @as(f64, if (kind == .failure) 10 else 6) };
        const title = std.fmt.bufPrint(n.title_buf[0 .. n.title_buf.len - 1], title_fmt, title_args) catch n.title_buf[0..0];
        n.title_len = title.len;
        n.title_buf[title.len] = 0;
        const detail = std.fmt.bufPrint(n.detail_buf[0 .. n.detail_buf.len - 1], detail_fmt, detail_args) catch n.detail_buf[0..0];
        n.detail_len = detail.len;
        n.detail_buf[detail.len] = 0;
        self.notice = n;
    }

    fn drawNotice(self: *App) void {
        if (self.notice == null) return;
        const notice = &self.notice.?;
        const now = rl.time();
        if (now >= notice.until) {
            self.notice = null;
            return;
        }
        const alpha: f32 = @floatCast(std.math.clamp((notice.until - now) / 0.4, 0, 1));

        const sw: f32 = @floatFromInt(rl.screenWidth());
        const sh: f32 = @floatFromInt(rl.screenHeight());
        const pad = self.s(14);
        const bar_w = self.s(4);
        const max_text_w = sw * 0.9 - pad * 2 - bar_w;

        var title_buf: [512]u8 = undefined;
        var detail_buf: [512]u8 = undefined;
        const title = self.typo.fit(&title_buf, notice.title_buf[0..notice.title_len], max_text_w, text_body);
        const detail = self.typo.fit(&detail_buf, notice.detail_buf[0..notice.detail_len], max_text_w, text_status);
        const has_detail = notice.detail_len > 0;

        const text_w = @max(self.typo.measure(title, text_body), if (has_detail) self.typo.measure(detail, text_status) else 0);
        const w = text_w + pad * 2 + bar_w;
        const h = pad * 2 + self.typo.pxF(text_body) + if (has_detail) self.s(5) + self.typo.pxF(text_status) else 0;
        const r = rl.Rectangle{ .x = @round((sw - w) / 2), .y = @round(sh - h - self.s(20)), .width = w, .height = h };

        const accent = switch (notice.kind) {
            .success => col_success_text,
            .info => col_accent,
            .failure => col_error_text,
        };
        rl.drawRectangleRounded(r, 0.12, 6, rl.fade(col_tooltip, alpha));
        rl.drawRectangleLines(r, 1, rl.fade(col_border, alpha));
        rl.drawRectangleRec(.{ .x = r.x + 1, .y = r.y + 1, .width = bar_w, .height = r.height - 2 }, rl.fade(accent, alpha));

        const tx = r.x + bar_w + pad;
        self.typo.draw(title, tx, r.y + pad, text_body, rl.fade(accent, alpha));
        if (has_detail) {
            self.typo.draw(detail, tx, r.y + pad + self.typo.pxF(text_body) + self.s(5), text_status, rl.fade(col_text_dim, alpha));
        }
    }

    // --- settings dialog -----------------------------------------------------

    fn drawSettings(self: *App) void {
        const sw: f32 = @floatFromInt(rl.screenWidth());
        const sh: f32 = @floatFromInt(rl.screenHeight());
        rl.drawRectangle(0, 0, @intFromFloat(sw), @intFromFloat(sh), col_overlay);

        const pad = self.s(20);
        const section_gap = self.s(18);
        const label_gap = self.s(8);
        const seg_h = self.typo.pxF(text_body) + self.s(16);
        const preview_h = self.typo.pxF(text_body) + self.s(20);
        const done_h = seg_h;

        const panel_w = @min(sw - self.s(40), self.s(560));
        const panel_h = pad + self.typo.pxF(text_heading) + section_gap +
            (self.typo.pxF(text_status) + label_gap + seg_h + section_gap) * 2 +
            self.typo.pxF(text_status) + label_gap + preview_h + section_gap + done_h + pad;
        const panel = rl.Rectangle{
            .x = @round((sw - panel_w) / 2),
            .y = @round(@max(self.s(10), (sh - panel_h) / 2)),
            .width = panel_w,
            .height = panel_h,
        };

        rl.drawRectangleRounded(panel, 0.04, 8, col_panel);
        rl.drawRectangleLines(panel, 1, col_border);

        var y = panel.y + pad;
        const x = panel.x + pad;
        const content_w = panel.width - pad * 2;

        self.typo.draw("Settings", x, y, text_heading, col_text);
        y += self.typo.pxF(text_heading) + section_gap;

        // Font family.
        self.typo.draw("Font", x, y, text_status, col_text_dim);
        y += self.typo.pxF(text_status) + label_gap;
        const font_labels = [_][:0]const u8{ FontChoice.arial.label(), FontChoice.times.label(), FontChoice.courier.label() };
        if (self.segmented(x, y, content_w, seg_h, &font_labels, @intFromEnum(self.settings.font))) |index| {
            var next = self.settings;
            next.font = @enumFromInt(index);
            self.applySettings(next);
        }
        y += seg_h + section_gap;

        // Text size.
        self.typo.draw("Text size", x, y, text_status, col_text_dim);
        y += self.typo.pxF(text_status) + label_gap;
        const size_labels = [_][:0]const u8{ SizeChoice.smaller.label(), SizeChoice.normal.label(), SizeChoice.larger.label() };
        if (self.segmented(x, y, content_w, seg_h, &size_labels, @intFromEnum(self.settings.size))) |index| {
            var next = self.settings;
            next.size = @enumFromInt(index);
            self.applySettings(next);
        }
        y += seg_h + section_gap;

        // Live preview of the current choice.
        self.typo.draw("Preview", x, y, text_status, col_text_dim);
        y += self.typo.pxF(text_status) + label_gap;
        const preview_box = rl.Rectangle{ .x = x, .y = y, .width = content_w, .height = preview_h };
        rl.drawRectangleRec(preview_box, col_bg);
        rl.drawRectangleLines(preview_box, 1, col_border);
        var preview_buf: [256]u8 = undefined;
        const preview = self.typo.fit(&preview_buf, preview_text, content_w - self.s(20), text_body);
        self.typo.drawCentered(preview, x + self.s(10), y, preview_h, text_body, col_text);
        y += preview_h + section_gap;

        if (!self.typo.usingTtf()) {
            self.typo.draw("Font file not found - using the built-in font", x, y + (done_h - self.typo.pxF(text_small)) / 2, text_small, col_text_dim);
        }

        // Done button (bottom right). Escape or a click outside also closes.
        var right = panel.x + panel.width - pad;
        const done = self.button(&right, y, "Done");
        const clicked_outside = clicked() and !rl.pointInRect(rl.mousePosition(), panel);
        const escape = input_enabled and rl.keyPressed(rl.key_escape);
        if (done or clicked_outside or escape) self.settings_open = false;
    }

    /// A row of equal-width toggle buttons. Returns the index clicked, if any.
    fn segmented(self: *App, x: f32, y: f32, w: f32, h: f32, labels: []const [:0]const u8, selected: usize) ?usize {
        const gap = self.s(6);
        const count: f32 = @floatFromInt(labels.len);
        const seg_w = (w - gap * (count - 1)) / count;
        var result: ?usize = null;

        for (labels, 0..) |label, i| {
            const r = rl.Rectangle{ .x = x + @as(f32, @floatFromInt(i)) * (seg_w + gap), .y = y, .width = seg_w, .height = h };
            const is_selected = i == selected;
            const hovered = hovering(r);
            const fill = if (is_selected) col_accent else if (hovered) col_panel_alt else col_bar;
            rl.drawRectangleRounded(r, 0.25, 6, fill);
            if (!is_selected) rl.drawRectangleLines(r, 1, if (hovered) col_accent else col_border);

            var buf: [64]u8 = undefined;
            const text = self.typo.fit(&buf, label, seg_w - self.s(12), text_body);
            const tw = self.typo.measure(text, text_body);
            self.typo.drawCentered(text, r.x + (r.width - tw) / 2, r.y, r.height, text_body, if (is_selected) col_bg else col_text);

            if (hovered and clicked() and !is_selected) result = i;
        }
        return result;
    }
};

// --- settings persistence ----------------------------------------------------

/// `<exe dir>/diskviz.ini`, NUL-terminated in `buf`.
fn settingsPath(buf: []u8) ?[:0]const u8 {
    const dir = std.mem.span(rl.applicationDirectory());
    const written = std.fmt.bufPrint(buf[0 .. buf.len - 1], "{s}{s}", .{ dir, settings_mod.file_name }) catch return null;
    buf[written.len] = 0;
    return buf[0..written.len :0];
}

fn loadSettings() Settings {
    var path_buf: [1024]u8 = undefined;
    const path = settingsPath(&path_buf) orelse return .{};
    if (!rl.fileExists(path.ptr)) return .{};
    const text = rl.loadFileText(path.ptr) orelse return .{};
    defer rl.unloadFileText(text);
    return settings_mod.parse(std.mem.span(text));
}

fn saveSettings(value: Settings) void {
    var path_buf: [1024]u8 = undefined;
    const path = settingsPath(&path_buf) orelse return;
    var text_buf: [256]u8 = undefined;
    const text = settings_mod.format(&text_buf, value) orelse return;
    _ = rl.saveFileText(path.ptr, text);
}

// --- small helpers -----------------------------------------------------------

fn colorFor(name: []const u8) rl.Color {
    const hash = std.hash.Wyhash.hash(0, name);
    return palette[@intCast(hash % palette.len)];
}

fn cmpSizeDesc(_: void, a: ChildSnapshot, b: ChildSnapshot) bool {
    return a.size > b.size;
}

/// Copy `text` into `buf` as a NUL-terminated slice (truncating if needed).
fn toZ(buf: []u8, text: []const u8) [:0]const u8 {
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

fn printZ(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    const written = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch buf[0..0];
    buf[written.len] = 0;
    return buf[0..written.len :0];
}
