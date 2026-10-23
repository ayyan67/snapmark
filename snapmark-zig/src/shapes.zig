const std = @import("std");

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const BaseShape = struct {
    id: u64,
    color: [4]f32,
    stroke_width: f64,
};

fn colorsEqual(a: [4]f32, b: [4]f32) bool {
    return std.mem.eql(f32, &a, &b);
}

pub const Freehand = struct {
    base: BaseShape,
    points: std.array_list.Managed(Point),

    pub fn init(allocator: std.mem.Allocator, base: BaseShape, start: Point) !Freehand {
        var points = std.array_list.Managed(Point).init(allocator);
        errdefer points.deinit();
        try points.append(start);

        return .{
            .base = base,
            .points = points,
        };
    }

    pub fn deinit(self: *Freehand) void {
        self.points.deinit();
    }

    pub fn clone(self: *const Freehand, allocator: std.mem.Allocator) !Freehand {
        var copied = std.array_list.Managed(Point).init(allocator);
        errdefer copied.deinit();
        try copied.appendSlice(self.points.items);
        return .{
            .base = self.base,
            .points = copied,
        };
    }

    pub fn equals(a: *const Freehand, b: *const Freehand) bool {
        if (a.base.id != b.base.id) return false;
        if (a.base.stroke_width != b.base.stroke_width) return false;
        if (!colorsEqual(a.base.color, b.base.color)) return false;
        if (a.points.items.len != b.points.items.len) return false;

        for (a.points.items, b.points.items) |ap, bp| {
            if (ap.x != bp.x or ap.y != bp.y) return false;
        }
        return true;
    }
};

pub const Circle = struct {
    base: BaseShape,
    center: Point,
    radius_x: f64,
    radius_y: f64,

    pub fn equals(a: *const Circle, b: *const Circle) bool {
        return a.base.id == b.base.id and
            a.base.stroke_width == b.base.stroke_width and
            colorsEqual(a.base.color, b.base.color) and
            a.center.x == b.center.x and
            a.center.y == b.center.y and
            a.radius_x == b.radius_x and
            a.radius_y == b.radius_y;
    }
};

pub const Rect = struct {
    base: BaseShape,
    origin: Point,
    width: f64,
    height: f64,

    pub fn equals(a: *const Rect, b: *const Rect) bool {
        return a.base.id == b.base.id and
            a.base.stroke_width == b.base.stroke_width and
            colorsEqual(a.base.color, b.base.color) and
            a.origin.x == b.origin.x and
            a.origin.y == b.origin.y and
            a.width == b.width and
            a.height == b.height;
    }
};

pub const Arrow = struct {
    base: BaseShape,
    start: Point,
    end: Point,

    pub fn equals(a: *const Arrow, b: *const Arrow) bool {
        return a.base.id == b.base.id and
            a.base.stroke_width == b.base.stroke_width and
            colorsEqual(a.base.color, b.base.color) and
            a.start.x == b.start.x and
            a.start.y == b.start.y and
            a.end.x == b.end.x and
            a.end.y == b.end.y;
    }
};

pub const Line = struct {
    base: BaseShape,
    start: Point,
    end: Point,

    pub fn equals(a: *const Line, b: *const Line) bool {
        return a.base.id == b.base.id and
            a.base.stroke_width == b.base.stroke_width and
            colorsEqual(a.base.color, b.base.color) and
            a.start.x == b.start.x and
            a.start.y == b.start.y and
            a.end.x == b.end.x and
            a.end.y == b.end.y;
    }
};

pub const Text = struct {
    base: BaseShape,
    position: Point,
    text: []u8,
    font_size: f64,

    pub fn init(
        allocator: std.mem.Allocator,
        base: BaseShape,
        position: Point,
        value: []const u8,
        font_size: f64,
    ) !Text {
        const copied = try allocator.dupe(u8, value);
        return .{
            .base = base,
            .position = position,
            .text = copied,
            .font_size = font_size,
        };
    }

    pub fn deinit(self: *Text, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }

    pub fn clone(self: *const Text, allocator: std.mem.Allocator) !Text {
        const copied = try allocator.dupe(u8, self.text);
        return .{
            .base = self.base,
            .position = self.position,
            .text = copied,
            .font_size = self.font_size,
        };
    }

    pub fn equals(a: *const Text, b: *const Text) bool {
        return a.base.id == b.base.id and
            a.base.stroke_width == b.base.stroke_width and
            colorsEqual(a.base.color, b.base.color) and
            a.position.x == b.position.x and
            a.position.y == b.position.y and
            a.font_size == b.font_size and
            std.mem.eql(u8, a.text, b.text);
    }
};

pub const Shape = union(enum) {
    freehand: Freehand,
    circle: Circle,
    rect: Rect,
    arrow: Arrow,
    line: Line,
    text: Text,

    pub fn deinit(self: *Shape, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .freehand => |*shape| shape.deinit(),
            .text => |*shape| shape.deinit(allocator),
            else => {},
        }
    }

    pub fn clone(self: *const Shape, allocator: std.mem.Allocator) !Shape {
        return switch (self.*) {
            .freehand => |shape| .{ .freehand = try shape.clone(allocator) },
            .circle => |shape| .{ .circle = shape },
            .rect => |shape| .{ .rect = shape },
            .arrow => |shape| .{ .arrow = shape },
            .line => |shape| .{ .line = shape },
            .text => |shape| .{ .text = try shape.clone(allocator) },
        };
    }

    pub fn equals(a: *const Shape, b: *const Shape) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;

        return switch (a.*) {
            .freehand => |shape| shape.equals(&b.freehand),
            .circle => |shape| shape.equals(&b.circle),
            .rect => |shape| shape.equals(&b.rect),
            .arrow => |shape| shape.equals(&b.arrow),
            .line => |shape| shape.equals(&b.line),
            .text => |shape| shape.equals(&b.text),
        };
    }

    pub fn id(self: *const Shape) u64 {
        return switch (self.*) {
            .freehand => |shape| shape.base.id,
            .circle => |shape| shape.base.id,
            .rect => |shape| shape.base.id,
            .arrow => |shape| shape.base.id,
            .line => |shape| shape.base.id,
            .text => |shape| shape.base.id,
        };
    }
};

pub fn makeBase(id: u64, color: [4]f32, stroke_width: f64) BaseShape {
    return .{
        .id = id,
        .color = color,
        .stroke_width = stroke_width,
    };
}
