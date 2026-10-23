const std = @import("std");
const math = @import("math.zig");
const shapes = @import("shapes.zig");

pub const HISTORY_LIMIT: usize = 100;
const HIT_TOLERANCE: f64 = 6.0;
const HANDLE_HIT_SIZE: f64 = 12.0;

pub const Tool = enum(u8) {
    select = 1,
    pen = 2,
    circle = 3,
    rect = 4,
    arrow = 5,
    line = 6,
    text = 7,
};

pub const ImageBuffer = struct {
    width: usize,
    height: usize,
    pixels: []u8,
};

const Snapshot = struct {
    shapes: std.array_list.Managed(shapes.Shape),

    fn init(allocator: std.mem.Allocator) Snapshot {
        return .{ .shapes = std.array_list.Managed(shapes.Shape).init(allocator) };
    }

    fn fromShapes(allocator: std.mem.Allocator, source: []const shapes.Shape) !Snapshot {
        var snapshot = Snapshot.init(allocator);
        errdefer snapshot.deinit(allocator);

        try snapshot.shapes.ensureTotalCapacity(source.len);
        for (source) |shape| {
            try snapshot.shapes.append(try shape.clone(allocator));
        }

        return snapshot;
    }

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.shapes.items) |*shape| {
            shape.deinit(allocator);
        }
        self.shapes.deinit();
    }

    fn equals(self: *const Snapshot, other: *const Snapshot) bool {
        if (self.shapes.items.len != other.shapes.items.len) return false;

        for (self.shapes.items, other.shapes.items) |left, right| {
            if (!left.equals(&right)) return false;
        }
        return true;
    }
};

const MoveInteraction = struct {
    shape_id: u64,
    last_point: shapes.Point,
    changed: bool,
};

const ResizeInteraction = struct {
    shape_id: u64,
    handle: math.ResizeHandle,
    changed: bool,
};

const ActiveTransform = union(enum) {
    none,
    moving: MoveInteraction,
    resizing: ResizeInteraction,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    start_ns: i128,
    startup_logged: bool,

    tool: Tool,
    color: [4]f32,
    stroke_width: f64,

    canvas_width: usize,
    canvas_height: usize,

    is_drawing: bool,
    temp_shape: ?shapes.Shape,
    next_shape_id: u64,

    selected_shape_id: ?u64,
    active_transform: ActiveTransform,

    shape_list: std.array_list.Managed(shapes.Shape),
    history: std.array_list.Managed(Snapshot),
    history_index: usize,

    background: ?ImageBuffer,

    pub fn init(allocator: std.mem.Allocator) !AppState {
        var state = AppState{
            .allocator = allocator,
            .start_ns = std.time.nanoTimestamp(),
            .startup_logged = false,
            .tool = .pen,
            .color = .{ 1.0, 0.0, 0.0, 1.0 },
            .stroke_width = 4.0,
            .canvas_width = 1024,
            .canvas_height = 672,
            .is_drawing = false,
            .temp_shape = null,
            .next_shape_id = 1,
            .selected_shape_id = null,
            .active_transform = .none,
            .shape_list = std.array_list.Managed(shapes.Shape).init(allocator),
            .history = std.array_list.Managed(Snapshot).init(allocator),
            .history_index = 0,
            .background = null,
        };

        try state.pushHistory();
        return state;
    }

    pub fn deinit(self: *AppState) void {
        self.cancelDrawing();

        self.clearShapes();
        self.shape_list.deinit();

        for (self.history.items) |*snapshot| {
            snapshot.deinit(self.allocator);
        }
        self.history.deinit();

        self.clearBackground();
    }

    pub fn setCanvasSize(self: *AppState, width: usize, height: usize) void {
        self.canvas_width = if (width == 0) self.canvas_width else width;
        self.canvas_height = if (height == 0) self.canvas_height else height;
    }

    pub fn setTool(self: *AppState, tool: Tool) void {
        if (self.tool != tool) {
            self.cancelDrawing();
            self.active_transform = .none;
            if (tool != .select) {
                self.selected_shape_id = null;
            }
            self.tool = tool;
        }
    }

    pub fn setToolFromKeyCode(self: *AppState, key_code: u16) void {
        const next_tool = switch (key_code) {
            18 => .select,
            19 => .pen,
            20 => .circle,
            21 => .rect,
            23 => .arrow,
            22 => .line,
            26 => .text,
            else => self.tool,
        };

        self.setTool(next_tool);
    }

    pub fn setColor(self: *AppState, color: [4]f32) void {
        self.color = color;
    }

    pub fn setStrokeWidth(self: *AppState, stroke_width: f64) void {
        self.stroke_width = @max(1.0, stroke_width);
    }

    pub fn clearDocument(self: *AppState) !bool {
        const had_data = self.shape_list.items.len > 0 or self.background != null;
        if (!had_data) return false;

        self.cancelDrawing();
        self.active_transform = .none;
        self.selected_shape_id = null;

        self.clearShapes();
        self.clearBackground();
        try self.pushHistory();
        return true;
    }

    pub fn textFontSize(self: *const AppState) f64 {
        return @max(16.0, self.stroke_width * 6.0);
    }

    pub fn addTextShape(self: *AppState, x: f64, y: f64, value: []const u8) !bool {
        if (value.len == 0) return false;

        const id = self.nextShapeId();
        const base = shapes.makeBase(id, self.color, self.stroke_width);
        const text_shape = try shapes.Text.init(
            self.allocator,
            base,
            .{ .x = x, .y = y },
            value,
            self.textFontSize(),
        );

        try self.shape_list.append(.{ .text = text_shape });
        self.selected_shape_id = id;
        self.active_transform = .none;
        try self.pushHistory();
        return true;
    }

    pub fn beginDrawing(self: *AppState, x: f64, y: f64, shift: bool) !void {
        const point = shapes.Point{ .x = x, .y = y };

        if (self.tool == .select) {
            self.beginSelectInteraction(point);
            return;
        }

        _ = shift;

        self.cancelDrawing();
        self.active_transform = .none;
        self.selected_shape_id = null;

        switch (self.tool) {
            .pen => {
                const base = shapes.makeBase(self.nextShapeId(), self.color, self.stroke_width);
                self.temp_shape = .{
                    .freehand = try shapes.Freehand.init(self.allocator, base, point),
                };
                self.is_drawing = true;
            },
            .circle => {
                const base = shapes.makeBase(self.nextShapeId(), self.color, self.stroke_width);
                self.temp_shape = .{
                    .circle = .{
                        .base = base,
                        .center = point,
                        .radius_x = 0,
                        .radius_y = 0,
                    },
                };
                self.is_drawing = true;
            },
            .rect => {
                const base = shapes.makeBase(self.nextShapeId(), self.color, self.stroke_width);
                self.temp_shape = .{
                    .rect = .{
                        .base = base,
                        .origin = point,
                        .width = 0,
                        .height = 0,
                    },
                };
                self.is_drawing = true;
            },
            .arrow => {
                const base = shapes.makeBase(self.nextShapeId(), self.color, self.stroke_width);
                self.temp_shape = .{
                    .arrow = .{
                        .base = base,
                        .start = point,
                        .end = point,
                    },
                };
                self.is_drawing = true;
            },
            .line => {
                const base = shapes.makeBase(self.nextShapeId(), self.color, self.stroke_width);
                self.temp_shape = .{
                    .line = .{
                        .base = base,
                        .start = point,
                        .end = point,
                    },
                };
                self.is_drawing = true;
            },
            .text => {
                _ = try self.addTextShape(point.x, point.y, "Text");
            },
            .select => {},
        }
    }

    pub fn appendDrawingPoint(self: *AppState, x: f64, y: f64, shift: bool) !void {
        if (self.tool == .select) {
            self.updateSelectInteraction(.{ .x = x, .y = y });
            return;
        }

        if (!self.is_drawing) return;

        if (self.temp_shape) |*temp| {
            switch (temp.*) {
                .freehand => |*freehand| {
                    if (freehand.points.items.len > 0) {
                        const last = freehand.points.items[freehand.points.items.len - 1];
                        if (last.x == x and last.y == y) return;
                    }
                    try freehand.points.append(.{ .x = x, .y = y });
                },
                .circle => |*circle| {
                    const dx = x - circle.center.x;
                    const dy = y - circle.center.y;

                    if (shift) {
                        const r = @sqrt(dx * dx + dy * dy);
                        circle.radius_x = r;
                        circle.radius_y = r;
                    } else {
                        circle.radius_x = @abs(dx);
                        circle.radius_y = @abs(dy);
                    }
                },
                .rect => |*rect| {
                    var w = x - rect.origin.x;
                    var h = y - rect.origin.y;

                    if (shift) {
                        const size = @max(@abs(w), @abs(h));
                        w = if (w < 0) -size else size;
                        h = if (h < 0) -size else size;
                    }

                    rect.width = w;
                    rect.height = h;
                },
                .arrow => |*arrow| {
                    arrow.end = .{ .x = x, .y = y };
                },
                .line => |*line| {
                    line.end = .{ .x = x, .y = y };
                },
                .text => {},
            }
        }
    }

    pub fn finishDrawing(self: *AppState) !bool {
        if (self.tool == .select) {
            return self.finishSelectInteraction();
        }

        if (!self.is_drawing) return false;

        self.is_drawing = false;

        if (self.temp_shape) |temp| {
            var shape = temp;
            self.temp_shape = null;

            if (!hasMinimumSize(&shape)) {
                shape.deinit(self.allocator);
                return false;
            }

            errdefer shape.deinit(self.allocator);
            try self.shape_list.append(shape);
            try self.pushHistory();
            return true;
        }

        return false;
    }

    pub fn cancelDrawing(self: *AppState) void {
        self.is_drawing = false;
        if (self.temp_shape) |*shape| {
            shape.deinit(self.allocator);
            self.temp_shape = null;
        }
    }

    pub fn deleteSelectedOrLast(self: *AppState) !bool {
        self.cancelDrawing();
        self.active_transform = .none;

        if (self.selected_shape_id) |selected_id| {
            if (self.shapeIndexById(selected_id)) |index| {
                var removed = self.shape_list.orderedRemove(index);
                removed.deinit(self.allocator);
                self.selected_shape_id = null;
                try self.pushHistory();
                return true;
            }
            self.selected_shape_id = null;
        }

        if (self.shape_list.items.len == 0) return false;

        var removed = self.shape_list.pop().?;
        removed.deinit(self.allocator);
        try self.pushHistory();
        return true;
    }

    pub fn deleteLastShape(self: *AppState) !bool {
        return self.deleteSelectedOrLast();
    }

    pub fn pushHistory(self: *AppState) !void {
        self.truncateFutureHistory();

        var snapshot = try Snapshot.fromShapes(self.allocator, self.shape_list.items);
        errdefer snapshot.deinit(self.allocator);

        if (self.history.items.len > 0) {
            const latest = &self.history.items[self.history.items.len - 1];
            if (latest.equals(&snapshot)) {
                snapshot.deinit(self.allocator);
                self.history_index = self.history.items.len - 1;
                return;
            }
        }

        try self.history.append(snapshot);

        if (self.history.items.len > HISTORY_LIMIT) {
            var removed = self.history.orderedRemove(0);
            removed.deinit(self.allocator);
            if (self.history_index > 0) {
                self.history_index -= 1;
            }
        }

        self.history_index = self.history.items.len - 1;
    }

    pub fn canUndo(self: *const AppState) bool {
        return self.history_index > 0;
    }

    pub fn canRedo(self: *const AppState) bool {
        return self.history_index + 1 < self.history.items.len;
    }

    pub fn undo(self: *AppState) !bool {
        if (!self.canUndo()) return false;

        self.history_index -= 1;
        try self.restoreSnapshot(&self.history.items[self.history_index]);
        return true;
    }

    pub fn redo(self: *AppState) !bool {
        if (!self.canRedo()) return false;

        self.history_index += 1;
        try self.restoreSnapshot(&self.history.items[self.history_index]);
        return true;
    }

    pub fn setBackground(self: *AppState, pixels: []const u8, width: usize, height: usize) !void {
        if (width == 0 or height == 0) return error.InvalidImageSize;
        if (pixels.len != width * height * 4) return error.InvalidImageBuffer;

        self.clearBackground();

        const copied = try self.allocator.alloc(u8, pixels.len);
        errdefer self.allocator.free(copied);
        @memcpy(copied, pixels);

        self.background = .{
            .width = width,
            .height = height,
            .pixels = copied,
        };
    }

    pub fn clearBackground(self: *AppState) void {
        if (self.background) |bg| {
            self.allocator.free(bg.pixels);
            self.background = null;
        }
    }

    pub fn getShapeById(self: *const AppState, id: u64) ?*const shapes.Shape {
        const index = self.shapeIndexById(id) orelse return null;
        return &self.shape_list.items[index];
    }

    pub fn getSelectedShape(self: *const AppState) ?*const shapes.Shape {
        const id = self.selected_shape_id orelse return null;
        return self.getShapeById(id);
    }

    pub fn getSelectedBounds(self: *const AppState) ?math.Bounds {
        const shape = self.getSelectedShape() orelse return null;
        return math.shapeBounds(shape);
    }

    fn nextShapeId(self: *AppState) u64 {
        const id = self.next_shape_id;
        self.next_shape_id += 1;
        return id;
    }

    fn clearShapes(self: *AppState) void {
        for (self.shape_list.items) |*shape| {
            shape.deinit(self.allocator);
        }
        self.shape_list.clearRetainingCapacity();
    }

    fn restoreSnapshot(self: *AppState, snapshot: *const Snapshot) !void {
        self.cancelDrawing();
        self.active_transform = .none;
        self.selected_shape_id = null;

        self.clearShapes();
        try self.shape_list.ensureTotalCapacity(snapshot.shapes.items.len);

        for (snapshot.shapes.items) |shape| {
            try self.shape_list.append(try shape.clone(self.allocator));
        }
    }

    fn truncateFutureHistory(self: *AppState) void {
        while (self.history.items.len > self.history_index + 1) {
            var removed = self.history.pop().?;
            removed.deinit(self.allocator);
        }
    }

    fn beginSelectInteraction(self: *AppState, point: shapes.Point) void {
        self.cancelDrawing();
        self.active_transform = .none;

        if (self.selected_shape_id) |selected_id| {
            if (self.getShapeById(selected_id)) |shape| {
                if (math.shapeBounds(shape)) |bounds| {
                    const handle = math.hitTestHandle(bounds, point, HANDLE_HIT_SIZE);
                    if (handle != .none) {
                        self.active_transform = .{
                            .resizing = .{
                                .shape_id = selected_id,
                                .handle = handle,
                                .changed = false,
                            },
                        };
                        return;
                    }
                }
            } else {
                self.selected_shape_id = null;
            }
        }

        const hit_shape_id = self.hitTestTopShapeId(point, HIT_TOLERANCE);
        if (hit_shape_id) |id| {
            self.selected_shape_id = id;
            self.active_transform = .{
                .moving = .{
                    .shape_id = id,
                    .last_point = point,
                    .changed = false,
                },
            };
        } else {
            self.selected_shape_id = null;
            self.active_transform = .none;
        }
    }

    fn updateSelectInteraction(self: *AppState, point: shapes.Point) void {
        switch (self.active_transform) {
            .none => {},
            .moving => |moving| {
                if (self.shapeByIdMut(moving.shape_id)) |shape| {
                    const dx = point.x - moving.last_point.x;
                    const dy = point.y - moving.last_point.y;

                    if (dx != 0 or dy != 0) {
                        math.offsetShape(shape, dx, dy);

                        self.active_transform = .{
                            .moving = .{
                                .shape_id = moving.shape_id,
                                .last_point = point,
                                .changed = true,
                            },
                        };
                    }
                } else {
                    self.active_transform = .none;
                    self.selected_shape_id = null;
                }
            },
            .resizing => |resizing| {
                if (self.shapeByIdMut(resizing.shape_id)) |shape| {
                    const changed = math.resizeShape(shape, resizing.handle, point);
                    self.active_transform = .{
                        .resizing = .{
                            .shape_id = resizing.shape_id,
                            .handle = resizing.handle,
                            .changed = resizing.changed or changed,
                        },
                    };
                } else {
                    self.active_transform = .none;
                    self.selected_shape_id = null;
                }
            },
        }
    }

    fn finishSelectInteraction(self: *AppState) !bool {
        const changed = switch (self.active_transform) {
            .none => false,
            .moving => |moving| moving.changed,
            .resizing => |resizing| resizing.changed,
        };

        self.active_transform = .none;

        if (!changed) return false;

        try self.pushHistory();
        return true;
    }

    fn hitTestTopShapeId(self: *const AppState, point: shapes.Point, tolerance: f64) ?u64 {
        var i = self.shape_list.items.len;
        while (i > 0) {
            i -= 1;
            const shape = &self.shape_list.items[i];
            if (math.hitTestShape(shape, point, tolerance)) {
                return shape.id();
            }
        }

        return null;
    }

    fn shapeIndexById(self: *const AppState, id: u64) ?usize {
        for (self.shape_list.items, 0..) |shape, index| {
            if (shape.id() == id) return index;
        }
        return null;
    }

    fn shapeByIdMut(self: *AppState, id: u64) ?*shapes.Shape {
        const index = self.shapeIndexById(id) orelse return null;
        return &self.shape_list.items[index];
    }
};

fn hasMinimumSize(shape: *const shapes.Shape) bool {
    return switch (shape.*) {
        .freehand => |freehand| freehand.points.items.len > 2,
        .circle => |circle| circle.radius_x > 2 or circle.radius_y > 2,
        .rect => |rect| @abs(rect.width) > 2 or @abs(rect.height) > 2,
        .arrow => |arrow| distance(arrow.start, arrow.end) > 2,
        .line => |line| distance(line.start, line.end) > 2,
        .text => |text_shape| text_shape.text.len > 0,
    };
}

fn distance(a: shapes.Point, b: shapes.Point) f64 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    return @sqrt(dx * dx + dy * dy);
}
