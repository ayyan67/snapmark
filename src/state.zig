const std = @import("std");
const c = @import("c.zig").c;
const math = @import("math.zig");
const shapes = @import("shapes.zig");

pub const HISTORY_LIMIT: usize = 100;

// Interaction sizes in view points; converted to doc space per use.
const HIT_TOLERANCE: f64 = 6.0;
const HANDLE_HIT_SIZE: f64 = 12.0;
const MIN_RESIZE_SIZE: f64 = 5.0;
const MIN_SHAPE_SIZE: f64 = 2.0;
// Space kept around the image inside the canvas, in view points. The shim
// uses the same value when it sizes the window to fit a pasted image.
pub const CANVAS_PADDING: f64 = 12.0;

pub const Tool = enum(u8) {
    select = 1,
    pen = 2,
    circle = 3,
    rect = 4,
    arrow = 5,
    line = 6,
    text = 7,
};

// Maps doc space (image pixels) to view space (canvas points).
pub const View = struct {
    scale: f64 = 1.0,
    offset_x: f64 = 0.0,
    offset_y: f64 = 0.0,

    pub fn toDoc(self: View, x: f64, y: f64) shapes.Point {
        return .{
            .x = (x - self.offset_x) / self.scale,
            .y = (y - self.offset_y) / self.scale,
        };
    }

    pub fn toView(self: View, p: shapes.Point) shapes.Point {
        return .{
            .x = p.x * self.scale + self.offset_x,
            .y = p.y * self.scale + self.offset_y,
        };
    }
};

pub const Background = struct {
    width: usize,
    height: usize,
    point_width: f64,
    point_height: f64,
    image: c.CGImageRef,
};

// The background pre-scaled to the exact device pixel size it is shown at, so
// each redraw is a 1:1 blit instead of a high-quality resample.
const ScaledBackground = struct {
    image: c.CGImageRef,
    device_scale: f64,
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
        for (self.shapes.items) |*shape| shape.deinit(allocator);
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
    stroke_width: f64, // view points

    canvas_width: f64,
    canvas_height: f64,
    backing_scale: f64,
    live_resize: bool,
    view: View,

    is_drawing: bool,
    temp_shape: ?shapes.Shape,
    next_shape_id: u64,

    selected_shape_id: ?u64,
    editing_text_id: ?u64,
    active_transform: ActiveTransform,

    shape_list: std.array_list.Managed(shapes.Shape),
    history: std.array_list.Managed(Snapshot),
    history_index: usize,

    background: ?Background,
    scaled_background: ?ScaledBackground,

    pub fn init(allocator: std.mem.Allocator) !AppState {
        var state = AppState{
            .allocator = allocator,
            .start_ns = std.time.nanoTimestamp(),
            .startup_logged = false,
            .tool = .pen,
            .color = .{ 1.0, 0.2, 0.2, 1.0 },
            .stroke_width = 4.0,
            .canvas_width = 960,
            .canvas_height = 640,
            .backing_scale = 2.0,
            .live_resize = false,
            .view = .{},
            .is_drawing = false,
            .temp_shape = null,
            .next_shape_id = 1,
            .selected_shape_id = null,
            .editing_text_id = null,
            .active_transform = .none,
            .shape_list = std.array_list.Managed(shapes.Shape).init(allocator),
            .history = std.array_list.Managed(Snapshot).init(allocator),
            .history_index = 0,
            .background = null,
            .scaled_background = null,
        };
        try state.pushHistory();
        return state;
    }

    pub fn deinit(self: *AppState) void {
        self.cancelDrawing();
        self.freeShapes();
        self.shape_list.deinit();
        for (self.history.items) |*snapshot| snapshot.deinit(self.allocator);
        self.history.deinit();
        self.clearBackground();
    }

    // ---- View / canvas ------------------------------------------------------

    pub fn setCanvasSize(self: *AppState, width: f64, height: f64, backing_scale: f64) void {
        if (width >= 1) self.canvas_width = width;
        if (height >= 1) self.canvas_height = height;
        if (backing_scale > 0) self.backing_scale = backing_scale;
        self.updateView();
    }

    fn updateView(self: *AppState) void {
        if (self.background) |bg| {
            const iw = @as(f64, @floatFromInt(bg.width));
            const ih = @as(f64, @floatFromInt(bg.height));
            const avail_w = @max(1.0, self.canvas_width - 2.0 * CANVAS_PADDING);
            const avail_h = @max(1.0, self.canvas_height - 2.0 * CANVAS_PADDING);
            // Fit the window, but never show the image larger than its own
            // point size (a Retina screenshot shows at 0.5 view pt per pixel).
            const native = bg.point_width / iw;
            const scale = @min(native, @min(avail_w / iw, avail_h / ih));
            self.view = .{
                .scale = scale,
                .offset_x = @round((self.canvas_width - iw * scale) / 2.0),
                .offset_y = @round((self.canvas_height - ih * scale) / 2.0),
            };
        } else {
            self.view = .{};
        }
    }

    pub fn docStrokeWidth(self: *const AppState) f64 {
        return self.stroke_width / self.view.scale;
    }

    pub fn textFontSize(self: *const AppState) f64 {
        return @max(16.0, self.stroke_width * 6.0);
    }

    pub fn docFontSize(self: *const AppState) f64 {
        return self.textFontSize() / self.view.scale;
    }

    fn hitTolerance(self: *const AppState) f64 {
        return HIT_TOLERANCE / self.view.scale;
    }

    fn handleHitSize(self: *const AppState) f64 {
        return HANDLE_HIT_SIZE / self.view.scale;
    }

    // ---- Settings -----------------------------------------------------------

    pub fn setTool(self: *AppState, tool: Tool) void {
        if (self.tool == tool) return;
        self.cancelDrawing();
        self.active_transform = .none;
        if (tool != .select) self.selected_shape_id = null;
        self.tool = tool;
    }

    pub fn setToolFromKeyCode(self: *AppState, key_code: u16) bool {
        const next_tool: Tool = switch (key_code) {
            18 => .select,
            19 => .pen,
            20 => .circle,
            21 => .rect,
            23 => .arrow,
            22 => .line,
            26 => .text,
            else => return false,
        };
        self.setTool(next_tool);
        return true;
    }

    pub fn setColor(self: *AppState, color: [4]f32) void {
        self.color = color;
    }

    pub fn setStrokeWidth(self: *AppState, stroke_width: f64) void {
        self.stroke_width = @max(1.0, stroke_width);
    }

    // ---- Shapes -------------------------------------------------------------

    // Drops all annotations and history; used when a new image is pasted.
    pub fn resetDocument(self: *AppState) !void {
        self.cancelDrawing();
        self.active_transform = .none;
        self.selected_shape_id = null;
        self.editing_text_id = null;
        self.freeShapes();
        for (self.history.items) |*snapshot| snapshot.deinit(self.allocator);
        self.history.clearRetainingCapacity();
        self.history_index = 0;
        try self.pushHistory();
    }

    pub fn clearAnnotations(self: *AppState) !bool {
        if (self.shape_list.items.len == 0 and self.temp_shape == null) return false;
        self.cancelDrawing();
        self.active_transform = .none;
        self.selected_shape_id = null;
        self.freeShapes();
        try self.pushHistory();
        return true;
    }

    pub fn addTextShape(self: *AppState, x: f64, y: f64, value: []const u8) !bool {
        if (value.len == 0) return false;
        const id = self.nextShapeId();
        const base = shapes.makeBase(id, self.color, self.docStrokeWidth());
        const text_shape = try shapes.Text.init(self.allocator, base, .{ .x = x, .y = y }, value, self.docFontSize());
        try self.shape_list.append(.{ .text = text_shape });
        self.selected_shape_id = id;
        self.active_transform = .none;
        try self.pushHistory();
        return true;
    }

    pub fn updateTextShape(self: *AppState, id: u64, value: []const u8) !bool {
        const index = self.shapeIndexById(id) orelse return false;
        if (value.len == 0) {
            var removed = self.shape_list.orderedRemove(index);
            removed.deinit(self.allocator);
            if (self.selected_shape_id == id) self.selected_shape_id = null;
            try self.pushHistory();
            return true;
        }
        switch (self.shape_list.items[index]) {
            .text => |*text_shape| {
                if (std.mem.eql(u8, text_shape.text, value)) return false;
                try text_shape.setText(self.allocator, value);
                try self.pushHistory();
                return true;
            },
            else => return false,
        }
    }

    pub fn textShapeAt(self: *const AppState, point: shapes.Point) ?*const shapes.Text {
        var i = self.shape_list.items.len;
        while (i > 0) {
            i -= 1;
            const shape = &self.shape_list.items[i];
            switch (shape.*) {
                .text => |*text_shape| {
                    if (math.hitTestShape(shape, point, self.hitTolerance())) return text_shape;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn beginDrawing(self: *AppState, view_x: f64, view_y: f64) !void {
        const point = self.view.toDoc(view_x, view_y);

        if (self.tool == .select) {
            self.beginSelectInteraction(point);
            return;
        }

        self.cancelDrawing();
        self.active_transform = .none;
        self.selected_shape_id = null;

        const base = shapes.makeBase(self.nextShapeId(), self.color, self.docStrokeWidth());
        switch (self.tool) {
            .pen => {
                self.temp_shape = .{ .freehand = try shapes.Freehand.init(self.allocator, base, point) };
                self.is_drawing = true;
            },
            .circle => {
                self.temp_shape = .{ .circle = .{ .base = base, .center = point, .radius_x = 0, .radius_y = 0 } };
                self.is_drawing = true;
            },
            .rect => {
                self.temp_shape = .{ .rect = .{ .base = base, .origin = point, .width = 0, .height = 0 } };
                self.is_drawing = true;
            },
            .arrow => {
                self.temp_shape = .{ .arrow = .{ .base = base, .start = point, .end = point } };
                self.is_drawing = true;
            },
            .line => {
                self.temp_shape = .{ .line = .{ .base = base, .start = point, .end = point } };
                self.is_drawing = true;
            },
            .text => {
                // The shim normally opens the inline editor instead; this is the
                // fallback when it does not.
                _ = try self.addTextShape(point.x, point.y, "Text");
            },
            .select => {},
        }
    }

    pub fn appendDrawingPoint(self: *AppState, view_x: f64, view_y: f64, shift: bool) !void {
        const point = self.view.toDoc(view_x, view_y);

        if (self.tool == .select) {
            self.updateSelectInteraction(point);
            return;
        }
        if (!self.is_drawing) return;

        const temp = &(self.temp_shape orelse return);
        switch (temp.*) {
            .freehand => |*freehand| {
                if (freehand.points.items.len > 0) {
                    const last = freehand.points.items[freehand.points.items.len - 1];
                    if (last.x == point.x and last.y == point.y) return;
                }
                try freehand.points.append(point);
            },
            .circle => |*circle| {
                const dx = point.x - circle.center.x;
                const dy = point.y - circle.center.y;
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
                var w = point.x - rect.origin.x;
                var h = point.y - rect.origin.y;
                if (shift) {
                    const size = @max(@abs(w), @abs(h));
                    w = if (w < 0) -size else size;
                    h = if (h < 0) -size else size;
                }
                rect.width = w;
                rect.height = h;
            },
            .arrow => |*arrow| arrow.end = point,
            .line => |*line| line.end = point,
            .text => {},
        }
    }

    pub fn finishDrawing(self: *AppState) !bool {
        if (self.tool == .select) return self.finishSelectInteraction();
        if (!self.is_drawing) return false;
        self.is_drawing = false;

        var shape = self.temp_shape orelse return false;
        self.temp_shape = null;

        if (!hasMinimumSize(&shape, MIN_SHAPE_SIZE / self.view.scale)) {
            shape.deinit(self.allocator);
            return false;
        }

        errdefer shape.deinit(self.allocator);
        try self.shape_list.append(shape);
        try self.pushHistory();
        return true;
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
            self.selected_shape_id = null;
            if (self.shapeIndexById(selected_id)) |index| {
                var removed = self.shape_list.orderedRemove(index);
                removed.deinit(self.allocator);
                try self.pushHistory();
                return true;
            }
        }

        if (self.shape_list.items.len == 0) return false;
        var removed = self.shape_list.pop().?;
        removed.deinit(self.allocator);
        try self.pushHistory();
        return true;
    }

    // ---- History ------------------------------------------------------------

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

    // ---- Background ---------------------------------------------------------

    // Takes ownership of a retained CGImage.
    pub fn setBackground(self: *AppState, image: c.CGImageRef, width: usize, height: usize, point_width: f64, point_height: f64) !void {
        if (image == null) return error.InvalidImage;
        if (width == 0 or height == 0) return error.InvalidImageSize;
        self.clearBackground();
        self.background = .{
            .width = width,
            .height = height,
            .point_width = if (point_width > 0) point_width else @as(f64, @floatFromInt(width)),
            .point_height = if (point_height > 0) point_height else @as(f64, @floatFromInt(height)),
            .image = image,
        };
        self.updateView();
    }

    pub fn clearBackground(self: *AppState) void {
        self.clearScaledBackground();
        if (self.background) |bg| {
            c.CGImageRelease(bg.image);
            self.background = null;
        }
        self.updateView();
    }

    fn clearScaledBackground(self: *AppState) void {
        if (self.scaled_background) |cache| {
            c.CGImageRelease(cache.image);
            self.scaled_background = null;
        }
    }

    // Returns the background rasterized at device_scale pixels per doc pixel,
    // building the cache on demand. Falls back to the full-size image.
    pub fn scaledBackgroundImage(self: *AppState, device_scale: f64) c.CGImageRef {
        const bg = self.background orelse return null;
        if (self.scaled_background) |cache| {
            if (@abs(cache.device_scale - device_scale) < 0.0001) return cache.image;
        }
        self.clearScaledBackground();
        if (@abs(device_scale - 1.0) < 0.0001) return bg.image;

        const w: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(bg.width)) * device_scale))));
        const h: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(bg.height)) * device_scale))));

        const colorspace = c.CGImageGetColorSpace(bg.image);
        const bitmap_info: c.CGBitmapInfo = c.kCGBitmapByteOrder32Big | c.kCGImageAlphaPremultipliedLast;
        const ctx = c.CGBitmapContextCreate(null, w, h, 8, 0, colorspace, bitmap_info);
        if (ctx == null) return bg.image;
        defer c.CGContextRelease(ctx);

        c.CGContextSetInterpolationQuality(ctx, c.kCGInterpolationHigh);
        c.CGContextSetBlendMode(ctx, c.kCGBlendModeCopy);
        c.CGContextDrawImage(ctx, c.CGRectMake(0, 0, @floatFromInt(w), @floatFromInt(h)), bg.image);

        const image = c.CGBitmapContextCreateImage(ctx);
        if (image == null) return bg.image;
        self.scaled_background = .{ .image = image, .device_scale = device_scale };
        return image;
    }

    // ---- Queries ------------------------------------------------------------

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

    // ---- Internals ----------------------------------------------------------

    fn nextShapeId(self: *AppState) u64 {
        const id = self.next_shape_id;
        self.next_shape_id += 1;
        return id;
    }

    fn freeShapes(self: *AppState) void {
        for (self.shape_list.items) |*shape| shape.deinit(self.allocator);
        self.shape_list.clearRetainingCapacity();
    }

    fn restoreSnapshot(self: *AppState, snapshot: *const Snapshot) !void {
        self.cancelDrawing();
        self.active_transform = .none;
        self.selected_shape_id = null;
        self.freeShapes();
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
                    const handle = math.hitTestHandle(bounds, point, self.handleHitSize());
                    if (handle != .none) {
                        self.active_transform = .{ .resizing = .{ .shape_id = selected_id, .handle = handle, .changed = false } };
                        return;
                    }
                }
            } else {
                self.selected_shape_id = null;
            }
        }

        if (self.hitTestTopShapeId(point)) |id| {
            self.selected_shape_id = id;
            self.active_transform = .{ .moving = .{ .shape_id = id, .last_point = point, .changed = false } };
        } else {
            self.selected_shape_id = null;
        }
    }

    fn updateSelectInteraction(self: *AppState, point: shapes.Point) void {
        switch (self.active_transform) {
            .none => {},
            .moving => |moving| {
                const shape = self.shapeByIdMut(moving.shape_id) orelse {
                    self.active_transform = .none;
                    self.selected_shape_id = null;
                    return;
                };
                const dx = point.x - moving.last_point.x;
                const dy = point.y - moving.last_point.y;
                if (dx != 0 or dy != 0) {
                    math.offsetShape(shape, dx, dy);
                    self.active_transform = .{ .moving = .{ .shape_id = moving.shape_id, .last_point = point, .changed = true } };
                }
            },
            .resizing => |resizing| {
                const shape = self.shapeByIdMut(resizing.shape_id) orelse {
                    self.active_transform = .none;
                    self.selected_shape_id = null;
                    return;
                };
                const changed = math.resizeShape(shape, resizing.handle, point, MIN_RESIZE_SIZE / self.view.scale);
                self.active_transform = .{ .resizing = .{
                    .shape_id = resizing.shape_id,
                    .handle = resizing.handle,
                    .changed = resizing.changed or changed,
                } };
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

    fn hitTestTopShapeId(self: *const AppState, point: shapes.Point) ?u64 {
        const tolerance = self.hitTolerance();
        var i = self.shape_list.items.len;
        while (i > 0) {
            i -= 1;
            const shape = &self.shape_list.items[i];
            if (math.hitTestShape(shape, point, tolerance)) return shape.id();
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

fn hasMinimumSize(shape: *const shapes.Shape, min_size: f64) bool {
    return switch (shape.*) {
        .freehand => |freehand| freehand.points.items.len > 2,
        .circle => |circle| circle.radius_x > min_size or circle.radius_y > min_size,
        .rect => |rect| @abs(rect.width) > min_size or @abs(rect.height) > min_size,
        .arrow => |arrow| math.distance(arrow.start, arrow.end) > min_size,
        .line => |line| math.distance(line.start, line.end) > min_size,
        .text => |text_shape| text_shape.text.len > 0,
    };
}
