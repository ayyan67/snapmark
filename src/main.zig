// Entry point and the C-callable surface the Objective-C shim uses. All of
// these run on the main thread.
const std = @import("std");
const c = @import("c.zig").c;
const state_mod = @import("state.zig");
const drawing = @import("drawing.zig");

const AppState = state_mod.AppState;
const allocator = std.heap.c_allocator;

pub fn main() void {
    c.sm_platform_run_app();
}

pub export fn sm_app_create() ?*AppState {
    const state = allocator.create(AppState) catch return null;
    state.* = AppState.init(allocator) catch {
        allocator.destroy(state);
        return null;
    };
    return state;
}

pub export fn sm_app_destroy(state: ?*AppState) void {
    const s = state orelse return;
    s.deinit();
    allocator.destroy(s);
}

// ---- Input -------------------------------------------------------------------

fn readModifiers(modifiers: ?*const c.SmModifiers) c.SmModifiers {
    return if (modifiers) |m| m.* else std.mem.zeroes(c.SmModifiers);
}

pub export fn sm_on_mouse_down(state: ?*AppState, x: f64, y: f64, modifiers: ?*const c.SmModifiers) void {
    _ = modifiers;
    const s = state orelse return;
    s.beginDrawing(x, y) catch return;
    c.sm_platform_invalidate();
}

pub export fn sm_on_mouse_drag(state: ?*AppState, x: f64, y: f64, modifiers: ?*const c.SmModifiers) void {
    const s = state orelse return;
    s.appendDrawingPoint(x, y, readModifiers(modifiers).shift != 0) catch return;
    c.sm_platform_invalidate();
}

pub export fn sm_on_mouse_up(state: ?*AppState, x: f64, y: f64, modifiers: ?*const c.SmModifiers) void {
    _ = x;
    _ = y;
    _ = modifiers;
    const s = state orelse return;
    _ = s.finishDrawing() catch false;
    c.sm_platform_invalidate();
}

pub export fn sm_on_key_down(state: ?*AppState, key_code: u16, modifiers_ptr: ?*const c.SmModifiers) bool {
    const s = state orelse return false;
    const modifiers = readModifiers(modifiers_ptr);

    if (modifiers.command != 0 or modifiers.control != 0) {
        switch (key_code) {
            9 => _ = sm_paste_from_clipboard(s),
            8 => _ = sm_copy_to_clipboard(s),
            6 => _ = if (modifiers.shift != 0) sm_redo(s) else sm_undo(s),
            else => return false,
        }
        return true;
    }

    switch (key_code) {
        53 => {
            c.sm_platform_hide_window();
            return true;
        },
        51, 117 => {
            _ = sm_delete_selected(s);
            return true;
        },
        else => {},
    }

    if (modifiers.option != 0) return false;
    if (s.setToolFromKeyCode(key_code)) {
        c.sm_platform_invalidate();
        return true;
    }
    return false;
}

// ---- Rendering ---------------------------------------------------------------

pub export fn sm_draw(state: ?*AppState, ctx: c.CGContextRef, width: f64, height: f64, scale: f64) void {
    const s = state orelse return;
    s.setCanvasSize(width, height, scale);
    drawing.draw(s, ctx, width, height, .screen);

    if (!s.startup_logged) {
        const elapsed_ns = std.time.nanoTimestamp() - s.start_ns;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        std.debug.print("startup_ms={d:.2}\n", .{elapsed_ms});
        s.startup_logged = true;
    }
}

pub export fn sm_set_live_resize(state: ?*AppState, live: bool) void {
    const s = state orelse return;
    s.live_resize = live;
}

// ---- Clipboard ---------------------------------------------------------------

pub export fn sm_paste_from_clipboard(state: ?*AppState) bool {
    const s = state orelse return false;

    // Re-pasting the same clipboard (or SnapMark's own export) would throw
    // away the annotations, so only load when the clipboard actually changed.
    if (s.background != null and !c.sm_platform_clipboard_changed()) return false;

    var image: c.CGImageRef = null;
    var width: usize = 0;
    var height: usize = 0;
    var point_width: f64 = 0;
    var point_height: f64 = 0;
    if (!c.sm_platform_read_clipboard_image(&image, &width, &height, &point_width, &point_height)) return false;
    if (image == null) return false;

    s.resetDocument() catch {
        c.CGImageRelease(image);
        return false;
    };
    s.setBackground(image, width, height, point_width, point_height) catch {
        c.CGImageRelease(image);
        return false;
    };

    c.sm_platform_background_changed();
    c.sm_platform_invalidate();
    return true;
}

// Renders the document and puts it on the clipboard as PNG. With a background
// the output is exactly the image's pixel size: no padding, no window chrome.
pub export fn sm_copy_to_clipboard(state: ?*AppState) bool {
    const s = state orelse return false;

    var px_w: usize = 0;
    var px_h: usize = 0;
    var doc_w: f64 = 0;
    var doc_h: f64 = 0;
    var point_w: f64 = 0;
    var point_h: f64 = 0;
    var scale: f64 = 1.0;
    var colorspace: c.CGColorSpaceRef = null;

    if (s.background) |bg| {
        px_w = bg.width;
        px_h = bg.height;
        doc_w = @floatFromInt(bg.width);
        doc_h = @floatFromInt(bg.height);
        point_w = bg.point_width;
        point_h = bg.point_height;
        colorspace = c.CGImageGetColorSpace(bg.image);
    } else {
        if (s.shape_list.items.len == 0) return false;
        scale = s.backing_scale;
        doc_w = s.canvas_width;
        doc_h = s.canvas_height;
        point_w = doc_w;
        point_h = doc_h;
        px_w = @intFromFloat(@round(doc_w * scale));
        px_h = @intFromFloat(@round(doc_h * scale));
    }
    if (px_w == 0 or px_h == 0) return false;

    const owned_colorspace: c.CGColorSpaceRef = if (colorspace == null) c.CGColorSpaceCreateWithName(c.kCGColorSpaceSRGB) else null;
    defer if (owned_colorspace != null) c.CGColorSpaceRelease(owned_colorspace);
    const cs = if (colorspace != null) colorspace else owned_colorspace;

    const pixels = allocator.alloc(u8, px_w * px_h * 4) catch return false;
    defer allocator.free(pixels);
    @memset(pixels, 0);

    const bitmap_info: c.CGBitmapInfo = c.kCGBitmapByteOrder32Big | c.kCGImageAlphaPremultipliedLast;
    const ctx = c.CGBitmapContextCreate(pixels.ptr, px_w, px_h, 8, px_w * 4, cs, bitmap_info);
    if (ctx == null) return false;
    defer c.CGContextRelease(ctx);

    c.CGContextSetInterpolationQuality(ctx, c.kCGInterpolationHigh);
    c.CGContextTranslateCTM(ctx, 0, @floatFromInt(px_h));
    c.CGContextScaleCTM(ctx, scale, -scale);
    drawing.draw(s, ctx, doc_w, doc_h, .clipboard);
    c.CGContextFlush(ctx);

    const out = c.SmImageBuffer{
        .pixels = pixels.ptr,
        .width = px_w,
        .height = px_h,
        .point_width = point_w,
        .point_height = point_h,
        .colorspace = cs,
    };
    return c.sm_platform_write_clipboard_rgba(&out);
}

// ---- Commands ----------------------------------------------------------------

pub export fn sm_undo(state: ?*AppState) bool {
    const s = state orelse return false;
    const changed = s.undo() catch false;
    c.sm_platform_invalidate();
    return changed;
}

pub export fn sm_redo(state: ?*AppState) bool {
    const s = state orelse return false;
    const changed = s.redo() catch false;
    c.sm_platform_invalidate();
    return changed;
}

pub export fn sm_delete_selected(state: ?*AppState) bool {
    const s = state orelse return false;
    const changed = s.deleteSelectedOrLast() catch false;
    c.sm_platform_invalidate();
    return changed;
}

pub export fn sm_clear_shapes(state: ?*AppState) bool {
    const s = state orelse return false;
    const changed = s.clearAnnotations() catch false;
    c.sm_platform_invalidate();
    return changed;
}

pub export fn sm_set_tool(state: ?*AppState, tool: u32) void {
    const s = state orelse return;
    if (tool < 1 or tool > 7) return;
    s.setTool(@enumFromInt(@as(u8, @intCast(tool))));
    c.sm_platform_invalidate();
}

pub export fn sm_set_color(state: ?*AppState, r: f32, g: f32, b: f32, a: f32) void {
    const s = state orelse return;
    s.setColor(.{ r, g, b, a });
    c.sm_platform_invalidate();
}

pub export fn sm_set_stroke_width(state: ?*AppState, stroke_width: f64) void {
    const s = state orelse return;
    s.setStrokeWidth(stroke_width);
    c.sm_platform_invalidate();
}

// ---- Queries -----------------------------------------------------------------

pub export fn sm_get_toolbar_model(state: ?*AppState, out_model: ?*c.SmToolbarModel) void {
    const s = state orelse return;
    const model = out_model orelse return;
    model.* = .{
        .selected_tool = @intFromEnum(s.tool),
        .can_undo = @intFromBool(s.canUndo()),
        .can_redo = @intFromBool(s.canRedo()),
        .has_background = @intFromBool(s.background != null),
        .has_selection = @intFromBool(s.tool == .select and s.getSelectedShape() != null),
        .has_shapes = @intFromBool(s.shape_list.items.len > 0),
        .reserved = .{ 0, 0 },
    };
}

pub export fn sm_get_text_style(state: ?*AppState, out_style: ?*c.SmTextStyle) void {
    const s = state orelse return;
    const style = out_style orelse return;
    style.* = .{
        .r = s.color[0],
        .g = s.color[1],
        .b = s.color[2],
        .a = s.color[3],
        .stroke_width = s.stroke_width,
        .font_size = s.textFontSize(),
    };
}

pub export fn sm_get_background_point_size(state: ?*AppState, out_width: ?*f64, out_height: ?*f64) bool {
    const s = state orelse return false;
    const bg = s.background orelse return false;
    if (out_width) |w| w.* = bg.point_width;
    if (out_height) |h| h.* = bg.point_height;
    return true;
}

// ---- Text editing ------------------------------------------------------------

pub export fn sm_text_hit_test(
    state: ?*AppState,
    view_x: f64,
    view_y: f64,
    out_edit: ?*c.SmTextEdit,
    buf: [*c]u8,
    cap: usize,
) bool {
    const s = state orelse return false;
    const out = out_edit orelse return false;
    const text_shape = s.textShapeAt(s.view.toDoc(view_x, view_y)) orelse return false;

    const origin = s.view.toView(text_shape.position);
    out.* = .{
        .shape_id = text_shape.base.id,
        .view_x = origin.x,
        .view_y = origin.y,
        .font_px = text_shape.font_size * s.view.scale,
        .r = text_shape.base.color[0],
        .g = text_shape.base.color[1],
        .b = text_shape.base.color[2],
        .a = text_shape.base.color[3],
        .text_len = text_shape.text.len,
    };
    if (buf != null) {
        const n = @min(cap, text_shape.text.len);
        @memcpy(buf[0..n], text_shape.text[0..n]);
    }

    s.editing_text_id = text_shape.base.id;
    c.sm_platform_invalidate();
    return true;
}

pub export fn sm_text_new_at(state: ?*AppState, view_x: f64, view_y: f64, out_edit: ?*c.SmTextEdit) void {
    const s = state orelse return;
    const out = out_edit orelse return;
    out.* = .{
        .shape_id = 0,
        .view_x = view_x,
        .view_y = view_y,
        .font_px = s.textFontSize(),
        .r = s.color[0],
        .g = s.color[1],
        .b = s.color[2],
        .a = s.color[3],
        .text_len = 0,
    };
}

pub export fn sm_text_commit(
    state: ?*AppState,
    shape_id: u64,
    view_x: f64,
    view_y: f64,
    text: [*c]const u8,
    text_len: usize,
) bool {
    const s = state orelse return false;
    s.editing_text_id = null;

    const empty: []const u8 = &.{};
    const value: []const u8 = if (text == null or text_len == 0) empty else text[0..text_len];

    const changed = if (shape_id != 0)
        s.updateTextShape(shape_id, value) catch false
    else if (value.len > 0) blk: {
        const p = s.view.toDoc(view_x, view_y);
        break :blk s.addTextShape(p.x, p.y, value) catch false;
    } else false;

    c.sm_platform_invalidate();
    return changed;
}
