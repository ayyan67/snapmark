const std = @import("std");
const c = @import("c.zig").c;

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

fn baseEqual(a: BaseShape, b: BaseShape) bool {
    return a.id == b.id and a.stroke_width == b.stroke_width and colorsEqual(a.color, b.color);
}

pub const Freehand = struct {
    base: BaseShape,
    points: std.array_list.Managed(Point),

    pub fn init(allocator: std.mem.Allocator, base: BaseShape, start: Point) !Freehand {
        var points = std.array_list.Managed(Point).init(allocator);
        errdefer points.deinit();
        try points.append(start);
        return .{ .base = base, .points = points };
    }

    pub fn deinit(self: *Freehand) void {
        self.points.deinit();
    }

    pub fn clone(self: *const Freehand, allocator: std.mem.Allocator) !Freehand {
        var copied = std.array_list.Managed(Point).init(allocator);
        errdefer copied.deinit();
        try copied.appendSlice(self.points.items);
        return .{ .base = self.base, .points = copied };
    }

    pub fn equals(a: *const Freehand, b: *const Freehand) bool {
        if (!baseEqual(a.base, b.base)) return false;
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
        return baseEqual(a.base, b.base) and
            a.center.x == b.center.x and a.center.y == b.center.y and
            a.radius_x == b.radius_x and a.radius_y == b.radius_y;
    }
};

pub const Rect = struct {
    base: BaseShape,
    origin: Point,
    width: f64,
    height: f64,

    pub fn equals(a: *const Rect, b: *const Rect) bool {
        return baseEqual(a.base, b.base) and
            a.origin.x == b.origin.x and a.origin.y == b.origin.y and
            a.width == b.width and a.height == b.height;
    }
};

pub const Arrow = struct {
    base: BaseShape,
    start: Point,
    end: Point,

    pub fn equals(a: *const Arrow, b: *const Arrow) bool {
        return baseEqual(a.base, b.base) and
            a.start.x == b.start.x and a.start.y == b.start.y and
            a.end.x == b.end.x and a.end.y == b.end.y;
    }
};

pub const Line = struct {
    base: BaseShape,
    start: Point,
    end: Point,

    pub fn equals(a: *const Line, b: *const Line) bool {
        return baseEqual(a.base, b.base) and
            a.start.x == b.start.x and a.start.y == b.start.y and
            a.end.x == b.end.x and a.end.y == b.end.y;
    }
};

pub const Text = struct {
    base: BaseShape,
    position: Point,
    text: []u8,
    font_size: f64,
    // Measured by the platform (CoreText) in the same units as font_size.
    width: f64,
    height: f64,

    pub fn init(
        allocator: std.mem.Allocator,
        base: BaseShape,
        position: Point,
        value: []const u8,
        font_size: f64,
    ) !Text {
        const copied = try allocator.dupe(u8, value);
        var shape = Text{
            .base = base,
            .position = position,
            .text = copied,
            .font_size = font_size,
            .width = 0,
            .height = 0,
        };
        shape.measure();
        return shape;
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
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn setText(self: *Text, allocator: std.mem.Allocator, value: []const u8) !void {
        const copied = try allocator.dupe(u8, value);
        allocator.free(self.text);
        self.text = copied;
        self.measure();
    }

    pub fn measure(self: *Text) void {
        var w: f64 = 0;
        var h: f64 = 0;
        c.sm_platform_measure_text(self.text.ptr, self.text.len, self.font_size, &w, &h);
        self.width = w;
        self.height = h;
    }

    pub fn equals(a: *const Text, b: *const Text) bool {
        return baseEqual(a.base, b.base) and
            a.position.x == b.position.x and a.position.y == b.position.y and
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
            inline else => |shape| shape.base.id,
        };
    }
};

pub fn makeBase(id: u64, color: [4]f32, stroke_width: f64) BaseShape {
    return .{ .id = id, .color = color, .stroke_width = stroke_width };
}
