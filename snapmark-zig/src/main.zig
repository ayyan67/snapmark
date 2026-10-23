const std = @import("std");
const c = @import("c.zig").c;
const state_mod = @import("state.zig");
const drawing = @import("drawing.zig");

const allocator = std.heap.c_allocator;

pub fn main() !void {
    c.sm_platform_run_app();
}

pub export fn sm_app_create() ?*state_mod.AppState {
    const state = allocator.create(state_mod.AppState) catch return null;
    state.* = state_mod.AppState.init(allocator) catch {
        allocator.destroy(state);
        return null;
    };
    return state;
}

pub export fn sm_app_destroy(state: ?*state_mod.AppState) void {
    const s = state orelse return;
    s.deinit();
    allocator.destroy(s);
}

pub export fn sm_on_mouse_down(state: ?*state_mod.AppState, x: f64, y: f64, modifiers: c.SmModifiers) void {
    const s = state orelse return;
    s.beginDrawing(x, y, modifiers.shift != 0) catch return;
    c.sm_platform_invalidate();
}

pub export fn sm_on_mouse_drag(state: ?*state_mod.AppState, x: f64, y: f64, modifiers: c.SmModifiers) void {
    const s = state orelse return;
    s.appendDrawingPoint(x, y, modifiers.shift != 0) catch return;
    c.sm_platform_invalidate();
}

pub export fn sm_on_mouse_up(state: ?*state_mod.AppState, x: f64, y: f64, modifiers: c.SmModifiers) void {
    _ = x;
    _ = y;
    _ = modifiers;

    const s = state orelse return;
    _ = s.finishDrawing() catch false;
    c.sm_platform_invalidate();
}

pub export fn sm_on_key_down(state: ?*state_mod.AppState, key_code: u16, modifiers: c.SmModifiers) void {
    const s = state orelse return;

    const is_command = modifiers.command != 0 or modifiers.control != 0;
    const is_shift = modifiers.shift != 0;

    if (is_command and key_code == 9) {
        _ = sm_paste_from_clipboard(s);
        return;
    }

    if (is_command and key_code == 8) {
        _ = sm_copy_to_clipboard(s);
        return;
    }

    if (is_command and key_code == 6) {
        if (is_shift) {
            _ = s.redo() catch false;
        } else {
            _ = s.undo() catch false;
        }
        c.sm_platform_invalidate();
        return;
    }

    if (key_code == 53) {
        c.sm_platform_hide_window();
        return;
    }

    if (key_code == 51 or key_code == 117) {
        _ = s.deleteSelectedOrLast() catch false;
        c.sm_platform_invalidate();
        return;
    }

    s.setToolFromKeyCode(key_code);
    c.sm_platform_invalidate();
}

pub export fn sm_draw(state: ?*state_mod.AppState, ctx: c.CGContextRef, width: f64, height: f64, scale: f64) void {
    const s = state orelse return;

    const canvas_w: usize = if (width < 1) 1 else @as(usize, @intFromFloat(width));
    const canvas_h: usize = if (height < 1) 1 else @as(usize, @intFromFloat(height));
    s.setCanvasSize(canvas_w, canvas_h);

    drawing.draw(s, ctx, width, height, scale);

    if (!s.startup_logged) {
        const elapsed_ns = std.time.nanoTimestamp() - s.start_ns;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
        std.debug.print("startup_ms={d:.2}\n", .{elapsed_ms});
        s.startup_logged = true;
    }
}

pub export fn sm_add_text(
    state: ?*state_mod.AppState,
    x: f64,
    y: f64,
    text: [*c]const u8,
    text_len: usize,
) bool {
    const s = state orelse return false;
    if (text == null or text_len == 0) return false;

    const text_ptr: [*]const u8 = @ptrCast(text);
    const value = text_ptr[0..text_len];
    const added = s.addTextShape(x, y, value) catch return false;

    if (added) {
        c.sm_platform_invalidate();
    }
    return added;
}

pub export fn sm_get_text_style(state: ?*state_mod.AppState, out_style: ?*c.SmTextStyle) void {
    const s = state orelse return;
    const style = out_style orelse return;

    style.r = s.color[0];
    style.g = s.color[1];
    style.b = s.color[2];
    style.a = s.color[3];
    style.stroke_width = s.stroke_width;
    style.font_size = s.textFontSize();
}

pub export fn sm_set_color(state: ?*state_mod.AppState, r: f32, g: f32, b: f32, a: f32) void {
    const s = state orelse return;
    s.setColor(.{ r, g, b, a });
    c.sm_platform_invalidate();
}

pub export fn sm_set_stroke_width(state: ?*state_mod.AppState, stroke_width: f64) void {
    const s = state orelse return;
    s.setStrokeWidth(stroke_width);
    c.sm_platform_invalidate();
}

pub export fn sm_clear_document(state: ?*state_mod.AppState) bool {
    const s = state orelse return false;
    const changed = s.clearDocument() catch return false;
    if (changed) {
        c.sm_platform_invalidate();
    }
    return changed;
}

pub export fn sm_paste_from_clipboard(state: ?*state_mod.AppState) bool {
    const s = state orelse return false;

    var image = c.SmImageBuffer{
        .pixels = null,
        .width = 0,
        .height = 0,
    };

    if (!c.sm_platform_read_clipboard_rgba(&image)) {
        return false;
    }

    if (image.pixels == null or image.width == 0 or image.height == 0) {
        return false;
    }
    defer c.sm_platform_free(image.pixels);

    const len = image.width * image.height * 4;
    const pixels = @as([*]u8, @ptrCast(image.pixels))[0..len];
    s.setBackground(pixels, image.width, image.height) catch return false;

    c.sm_platform_invalidate();
    return true;
}

pub export fn sm_copy_to_clipboard(state: ?*state_mod.AppState) bool {
    const s = state orelse return false;

    const width: usize = s.canvas_width;
    const height: usize = s.canvas_height;
    if (width == 0 or height == 0) return false;

    const len = width * height * 4;
    const pixels = allocator.alloc(u8, len) catch return false;
    defer allocator.free(pixels);
    @memset(pixels, 0);

    const colorspace = c.CGColorSpaceCreateDeviceRGB();
    if (colorspace == null) return false;
    defer c.CGColorSpaceRelease(colorspace);

    const bitmap_info: c.CGBitmapInfo = c.kCGBitmapByteOrder32Big | c.kCGImageAlphaPremultipliedLast;
    const ctx = c.CGBitmapContextCreate(
        pixels.ptr,
        width,
        height,
        8,
        width * 4,
        colorspace,
        bitmap_info,
    );
    if (ctx == null) return false;
    defer c.CGContextRelease(ctx);

    const width_f = @as(f64, @floatFromInt(width));
    const height_f = @as(f64, @floatFromInt(height));

    c.CGContextSaveGState(ctx);
    c.CGContextTranslateCTM(ctx, 0, height_f);
    c.CGContextScaleCTM(ctx, 1, -1);
    drawing.draw(s, ctx, width_f, height_f, 1.0);
    c.CGContextRestoreGState(ctx);

    const image = c.SmImageBuffer{
        .pixels = pixels.ptr,
        .width = width,
        .height = height,
    };

    return c.sm_platform_write_clipboard_rgba(&image);
}

pub export fn sm_get_toolbar_model(state: ?*state_mod.AppState, out_model: ?*c.SmToolbarModel) void {
    const s = state orelse return;
    const model = out_model orelse return;

    model.selected_tool = @intFromEnum(s.tool);
    model.can_undo = if (s.canUndo()) 1 else 0;
    model.can_redo = if (s.canRedo()) 1 else 0;
    model.reserved = 0;
}

pub export fn sm_toolbar_click(state: ?*state_mod.AppState, action_id: u32) void {
    const s = state orelse return;

    switch (action_id) {
        1 => s.setTool(.select),
        2 => s.setTool(.pen),
        3 => s.setTool(.circle),
        4 => s.setTool(.rect),
        5 => s.setTool(.arrow),
        6 => s.setTool(.line),
        7 => s.setTool(.text),
        else => {},
    }

    c.sm_platform_invalidate();
}
