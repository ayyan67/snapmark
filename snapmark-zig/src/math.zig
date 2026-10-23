const shapes = @import("shapes.zig");

pub const ResizeHandle = enum {
    none,
    n,
    ne,
    e,
    se,
    s,
    sw,
    w,
    nw,
};

pub const Bounds = struct {
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,

    pub fn width(self: Bounds) f64 {
        return self.max_x - self.min_x;
    }

    pub fn height(self: Bounds) f64 {
        return self.max_y - self.min_y;
    }
};

pub const handle_order = [_]ResizeHandle{ .nw, .n, .ne, .e, .se, .s, .sw, .w };

pub fn shapeBounds(shape: *const shapes.Shape) ?Bounds {
    return switch (shape.*) {
        .freehand => |freehand| {
            if (freehand.points.items.len == 0) return null;

            var min_x = freehand.points.items[0].x;
            var min_y = freehand.points.items[0].y;
            var max_x = min_x;
            var max_y = min_y;

            for (freehand.points.items[1..]) |point| {
                min_x = @min(min_x, point.x);
                min_y = @min(min_y, point.y);
                max_x = @max(max_x, point.x);
                max_y = @max(max_y, point.y);
            }

            return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
        },
        .circle => |circle| .{
            .min_x = circle.center.x - circle.radius_x,
            .min_y = circle.center.y - circle.radius_y,
            .max_x = circle.center.x + circle.radius_x,
            .max_y = circle.center.y + circle.radius_y,
        },
        .rect => |rect| {
            const min_x = @min(rect.origin.x, rect.origin.x + rect.width);
            const min_y = @min(rect.origin.y, rect.origin.y + rect.height);
            const max_x = @max(rect.origin.x, rect.origin.x + rect.width);
            const max_y = @max(rect.origin.y, rect.origin.y + rect.height);
            return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
        },
        .arrow => |arrow| .{
            .min_x = @min(arrow.start.x, arrow.end.x),
            .min_y = @min(arrow.start.y, arrow.end.y),
            .max_x = @max(arrow.start.x, arrow.end.x),
            .max_y = @max(arrow.start.y, arrow.end.y),
        },
        .line => |line| .{
            .min_x = @min(line.start.x, line.end.x),
            .min_y = @min(line.start.y, line.end.y),
            .max_x = @max(line.start.x, line.end.x),
            .max_y = @max(line.start.y, line.end.y),
        },
        .text => |text_shape| {
            const width = @as(f64, @floatFromInt(text_shape.text.len)) * text_shape.font_size * 0.6;
            const height = text_shape.font_size * 1.2;
            return .{
                .min_x = text_shape.position.x,
                .min_y = text_shape.position.y,
                .max_x = text_shape.position.x + width,
                .max_y = text_shape.position.y + height,
            };
        },
    };
}

pub fn hitTestShape(shape: *const shapes.Shape, point: shapes.Point, tolerance: f64) bool {
    return switch (shape.*) {
        .freehand => |freehand| hitTestFreehand(&freehand, point, tolerance),
        .circle => |circle| hitTestCircle(&circle, point, tolerance),
        .rect => |rect| hitTestRect(&rect, point, tolerance),
        .arrow => |arrow| hitTestSegment(arrow.start, arrow.end, point, arrow.base.stroke_width + tolerance),
        .line => |line| hitTestSegment(line.start, line.end, point, line.base.stroke_width + tolerance),
        .text => |text_shape| hitTestText(&text_shape, point, tolerance),
    };
}

pub fn hitTestHandle(bounds: Bounds, point: shapes.Point, size: f64) ResizeHandle {
    for (handle_order) |handle| {
        const center = handleCenter(bounds, handle);
        if (pointInSquare(point, center, size)) return handle;
    }
    return .none;
}

pub fn handleCenter(bounds: Bounds, handle: ResizeHandle) shapes.Point {
    const mid_x = (bounds.min_x + bounds.max_x) / 2.0;
    const mid_y = (bounds.min_y + bounds.max_y) / 2.0;

    return switch (handle) {
        .nw => .{ .x = bounds.min_x, .y = bounds.min_y },
        .n => .{ .x = mid_x, .y = bounds.min_y },
        .ne => .{ .x = bounds.max_x, .y = bounds.min_y },
        .e => .{ .x = bounds.max_x, .y = mid_y },
        .se => .{ .x = bounds.max_x, .y = bounds.max_y },
        .s => .{ .x = mid_x, .y = bounds.max_y },
        .sw => .{ .x = bounds.min_x, .y = bounds.max_y },
        .w => .{ .x = bounds.min_x, .y = mid_y },
        .none => .{ .x = mid_x, .y = mid_y },
    };
}

pub fn offsetShape(shape: *shapes.Shape, dx: f64, dy: f64) void {
    switch (shape.*) {
        .freehand => |*freehand| {
            for (freehand.points.items) |*point| {
                point.x += dx;
                point.y += dy;
            }
        },
        .circle => |*circle| {
            circle.center.x += dx;
            circle.center.y += dy;
        },
        .rect => |*rect| {
            rect.origin.x += dx;
            rect.origin.y += dy;
        },
        .arrow => |*arrow| {
            arrow.start.x += dx;
            arrow.start.y += dy;
            arrow.end.x += dx;
            arrow.end.y += dy;
        },
        .line => |*line| {
            line.start.x += dx;
            line.start.y += dy;
            line.end.x += dx;
            line.end.y += dy;
        },
        .text => |*text_shape| {
            text_shape.position.x += dx;
            text_shape.position.y += dy;
        },
    }
}

pub fn resizeShape(shape: *shapes.Shape, handle: ResizeHandle, cursor: shapes.Point) bool {
    if (handle == .none) return false;

    const old_bounds = shapeBounds(shape) orelse return false;
    var new_bounds = old_bounds;
    resizeBounds(&new_bounds, handle, cursor, 5.0);

    if (boundsEqual(old_bounds, new_bounds)) return false;

    const old_w = @max(1.0, old_bounds.width());
    const old_h = @max(1.0, old_bounds.height());
    const new_w = @max(1.0, new_bounds.width());
    const new_h = @max(1.0, new_bounds.height());

    const sx = new_w / old_w;
    const sy = new_h / old_h;

    const mapPoint = struct {
        fn run(p: shapes.Point, before: Bounds, after: Bounds, width_scale: f64, height_scale: f64) shapes.Point {
            return .{
                .x = after.min_x + (p.x - before.min_x) * width_scale,
                .y = after.min_y + (p.y - before.min_y) * height_scale,
            };
        }
    }.run;

    switch (shape.*) {
        .freehand => |*freehand| {
            for (freehand.points.items) |*point| {
                point.* = mapPoint(point.*, old_bounds, new_bounds, sx, sy);
            }
        },
        .circle => |*circle| {
            circle.center = .{
                .x = (new_bounds.min_x + new_bounds.max_x) / 2.0,
                .y = (new_bounds.min_y + new_bounds.max_y) / 2.0,
            };
            circle.radius_x = new_w / 2.0;
            circle.radius_y = new_h / 2.0;
        },
        .rect => |*rect| {
            rect.origin = .{ .x = new_bounds.min_x, .y = new_bounds.min_y };
            rect.width = new_w;
            rect.height = new_h;
        },
        .arrow => |*arrow| {
            arrow.start = mapPoint(arrow.start, old_bounds, new_bounds, sx, sy);
            arrow.end = mapPoint(arrow.end, old_bounds, new_bounds, sx, sy);
        },
        .line => |*line| {
            line.start = mapPoint(line.start, old_bounds, new_bounds, sx, sy);
            line.end = mapPoint(line.end, old_bounds, new_bounds, sx, sy);
        },
        .text => |*text_shape| {
            text_shape.position = mapPoint(text_shape.position, old_bounds, new_bounds, sx, sy);
            const scale = @max(0.5, (sx + sy) * 0.5);
            text_shape.font_size = @max(8.0, text_shape.font_size * scale);
        },
    }

    return true;
}

fn hitTestFreehand(shape: *const shapes.Freehand, point: shapes.Point, tolerance: f64) bool {
    if (shape.points.items.len < 2) return false;

    const threshold = shape.base.stroke_width + tolerance;
    var i: usize = 1;
    while (i < shape.points.items.len) : (i += 1) {
        if (pointToSegmentDistance(point, shape.points.items[i - 1], shape.points.items[i]) <= threshold) {
            return true;
        }
    }

    return false;
}

fn hitTestCircle(shape: *const shapes.Circle, point: shapes.Point, tolerance: f64) bool {
    if (shape.radius_x <= 0 or shape.radius_y <= 0) return false;

    const nx = (point.x - shape.center.x) / shape.radius_x;
    const ny = (point.y - shape.center.y) / shape.radius_y;
    const d = nx * nx + ny * ny;

    const min_radius = @max(1.0, @min(shape.radius_x, shape.radius_y));
    const tol = tolerance / min_radius;
    return d <= 1.0 + tol;
}

fn hitTestRect(shape: *const shapes.Rect, point: shapes.Point, tolerance: f64) bool {
    const bounds = shapeBounds(&shapes.Shape{ .rect = shape.* }) orelse return false;
    return point.x >= bounds.min_x - tolerance and
        point.x <= bounds.max_x + tolerance and
        point.y >= bounds.min_y - tolerance and
        point.y <= bounds.max_y + tolerance;
}

fn hitTestText(shape: *const shapes.Text, point: shapes.Point, tolerance: f64) bool {
    const bounds = shapeBounds(&shapes.Shape{ .text = shape.* }) orelse return false;
    return point.x >= bounds.min_x - tolerance and
        point.x <= bounds.max_x + tolerance and
        point.y >= bounds.min_y - tolerance and
        point.y <= bounds.max_y + tolerance;
}

fn hitTestSegment(start: shapes.Point, end: shapes.Point, point: shapes.Point, threshold: f64) bool {
    return pointToSegmentDistance(point, start, end) <= threshold;
}

fn pointToSegmentDistance(p: shapes.Point, a: shapes.Point, b: shapes.Point) f64 {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const wx = p.x - a.x;
    const wy = p.y - a.y;

    const seg_len2 = vx * vx + vy * vy;
    if (seg_len2 <= 0.000001) return distance(p, a);

    var t = (wx * vx + wy * vy) / seg_len2;
    t = @max(0.0, @min(1.0, t));

    const proj = shapes.Point{ .x = a.x + vx * t, .y = a.y + vy * t };
    return distance(p, proj);
}

fn distance(a: shapes.Point, b: shapes.Point) f64 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    return @sqrt(dx * dx + dy * dy);
}

fn pointInSquare(point: shapes.Point, center: shapes.Point, size: f64) bool {
    const half = size / 2.0;
    return point.x >= center.x - half and
        point.x <= center.x + half and
        point.y >= center.y - half and
        point.y <= center.y + half;
}

fn resizeBounds(bounds: *Bounds, handle: ResizeHandle, cursor: shapes.Point, min_size: f64) void {
    switch (handle) {
        .nw => {
            bounds.min_x = @min(cursor.x, bounds.max_x - min_size);
            bounds.min_y = @min(cursor.y, bounds.max_y - min_size);
        },
        .n => bounds.min_y = @min(cursor.y, bounds.max_y - min_size),
        .ne => {
            bounds.max_x = @max(cursor.x, bounds.min_x + min_size);
            bounds.min_y = @min(cursor.y, bounds.max_y - min_size);
        },
        .e => bounds.max_x = @max(cursor.x, bounds.min_x + min_size),
        .se => {
            bounds.max_x = @max(cursor.x, bounds.min_x + min_size);
            bounds.max_y = @max(cursor.y, bounds.min_y + min_size);
        },
        .s => bounds.max_y = @max(cursor.y, bounds.min_y + min_size),
        .sw => {
            bounds.min_x = @min(cursor.x, bounds.max_x - min_size);
            bounds.max_y = @max(cursor.y, bounds.min_y + min_size);
        },
        .w => bounds.min_x = @min(cursor.x, bounds.max_x - min_size),
        .none => {},
    }
}

fn boundsEqual(a: Bounds, b: Bounds) bool {
    return a.min_x == b.min_x and
        a.min_y == b.min_y and
        a.max_x == b.max_x and
        a.max_y == b.max_y;
}
