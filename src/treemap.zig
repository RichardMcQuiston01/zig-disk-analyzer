//! Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
//!
//! Pure geometry: given a list of weights and a rectangle, produce one child
//! rectangle per weight whose area is proportional to the weight, while keeping
//! each rectangle as close to square as possible. No allocation, no I/O — which
//! makes it trivially unit-testable.

const std = @import("std");

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn area(self: Rect) f32 {
        return self.w * self.h;
    }

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.w and
            py >= self.y and py <= self.y + self.h;
    }
};

/// Lay `sizes` out inside `area`, writing one rectangle per entry into `out`.
///
/// Requirements:
///   * `out.len == sizes.len`
///   * `sizes` is sorted in descending order (callers sort the backing nodes)
/// Zero-sized entries receive zero-area rectangles. The result always stays
/// within `area`.
pub fn squarify(sizes: []const u64, area: Rect, out: []Rect) void {
    std.debug.assert(sizes.len == out.len);
    if (sizes.len == 0) return;

    var total: u128 = 0;
    for (sizes) |s| total += s;
    if (total == 0 or area.w <= 0 or area.h <= 0) {
        for (out) |*r| r.* = .{ .x = area.x, .y = area.y };
        return;
    }

    const area_value: f64 = @as(f64, area.w) * @as(f64, area.h);
    const scale: f64 = area_value / @as(f64, @floatFromInt(total));

    var free_x: f64 = area.x;
    var free_y: f64 = area.y;
    var free_w: f64 = area.w;
    var free_h: f64 = area.h;

    var i: usize = 0;
    while (i < sizes.len) {
        const shorter_side = @min(free_w, free_h);

        // Greedily extend the current row while the worst aspect ratio improves.
        var j = i;
        var row_area: f64 = 0;
        var best_ratio: f64 = std.math.inf(f64);
        while (j < sizes.len) {
            const scaled = scaledArea(sizes[j], scale);
            const candidate_area = row_area + scaled;
            const ratio = worstRatio(sizes, scale, i, j + 1, candidate_area, shorter_side);
            if (ratio <= best_ratio) {
                best_ratio = ratio;
                row_area = candidate_area;
                j += 1;
            } else break;
        }

        // Lay the finished row [i, j) across the shorter side of the free rect.
        const thickness = if (shorter_side > 0) row_area / shorter_side else 0;
        if (free_w >= free_h) {
            var offset = free_y;
            var k = i;
            while (k < j) : (k += 1) {
                const length = cellLength(sizes[k], scale, thickness);
                out[k] = .{
                    .x = @floatCast(free_x),
                    .y = @floatCast(offset),
                    .w = @floatCast(thickness),
                    .h = @floatCast(length),
                };
                offset += length;
            }
            free_x += thickness;
            free_w -= thickness;
        } else {
            var offset = free_x;
            var k = i;
            while (k < j) : (k += 1) {
                const length = cellLength(sizes[k], scale, thickness);
                out[k] = .{
                    .x = @floatCast(offset),
                    .y = @floatCast(free_y),
                    .w = @floatCast(length),
                    .h = @floatCast(thickness),
                };
                offset += length;
            }
            free_y += thickness;
            free_h -= thickness;
        }

        i = j;
    }
}

fn scaledArea(size: u64, scale: f64) f64 {
    return @as(f64, @floatFromInt(size)) * scale;
}

fn cellLength(size: u64, scale: f64, thickness: f64) f64 {
    if (thickness <= 0) return 0;
    return scaledArea(size, scale) / thickness;
}

/// Worst (largest) width/height aspect ratio among the items in [start, end)
/// if they were laid out as a single row of the given area and side length.
fn worstRatio(sizes: []const u64, scale: f64, start: usize, end: usize, row_area: f64, shorter_side: f64) f64 {
    if (row_area <= 0 or shorter_side <= 0) return std.math.inf(f64);
    const thickness = row_area / shorter_side;
    var worst: f64 = 0;
    var k = start;
    while (k < end) : (k += 1) {
        const cell = scaledArea(sizes[k], scale);
        if (cell <= 0) continue;
        const length = cell / thickness;
        const ratio = @max(thickness / length, length / thickness);
        worst = @max(worst, ratio);
    }
    return worst;
}

test "areas are proportional and bounded" {
    const sizes = [_]u64{ 6, 6, 4, 3, 2, 2, 1 };
    const area = Rect{ .x = 0, .y = 0, .w = 6, .h = 4 }; // area 24 == sum, so scale == 1
    var out: [sizes.len]Rect = undefined;
    squarify(&sizes, area, &out);

    var total_area: f32 = 0;
    for (sizes, out) |size, rect| {
        const expected: f32 = @floatFromInt(size);
        try std.testing.expectApproxEqAbs(expected, rect.area(), 0.01);
        // every cell stays inside the parent rectangle
        try std.testing.expect(rect.x >= area.x - 0.001);
        try std.testing.expect(rect.y >= area.y - 0.001);
        try std.testing.expect(rect.x + rect.w <= area.x + area.w + 0.001);
        try std.testing.expect(rect.y + rect.h <= area.y + area.h + 0.001);
        total_area += rect.area();
    }
    try std.testing.expectApproxEqAbs(area.area(), total_area, 0.01);
}

test "single element fills the area" {
    const sizes = [_]u64{100};
    const area = Rect{ .x = 10, .y = 20, .w = 40, .h = 30 };
    var out: [1]Rect = undefined;
    squarify(&sizes, area, &out);
    try std.testing.expectApproxEqAbs(area.x, out[0].x, 0.001);
    try std.testing.expectApproxEqAbs(area.y, out[0].y, 0.001);
    try std.testing.expectApproxEqAbs(area.w, out[0].w, 0.001);
    try std.testing.expectApproxEqAbs(area.h, out[0].h, 0.001);
}

test "zero total produces zero rects without crashing" {
    const sizes = [_]u64{ 0, 0 };
    const area = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    var out: [2]Rect = undefined;
    squarify(&sizes, area, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].area(), 0.001);
}
