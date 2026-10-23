const c = @import("c.zig").c;
const math = @import("math.zig");
const shapes = @import("shapes.zig");
const state_mod = @import("state.zig");

const HANDLE_SIZE: f64 = 8.0;

pub fn draw(state: *const state_mod.AppState, ctx: c.CGContextRef, width: f64, height: f64, scale: f64) void {
    _ = scale;
    if (ctx == null) return;

    c.CGContextSetRGBFillColor(ctx, 0.07, 0.08, 0.10, 1.0);
    c.CGContextFillRect(ctx, c.CGRectMake(0, 0, width, height));

    if (state.background) |bg| {
        drawBackgroundImage(ctx, width, height, bg);
    } else {
        drawCheckerboard(ctx, width, height);
    }

    for (state.shape_list.items) |shape| {
        drawShape(ctx, shape);
    }

    if (state.temp_shape) |shape| {
        drawShape(ctx, shape);
    }

    if (state.tool == .select) {
        drawSelectionOverlay(state, ctx);
    }
}

fn drawCheckerboard(ctx: c.CGContextRef, width: f64, height: f64) void {
    const cell = 20.0;
    var y: f64 = 0;
    while (y < height) : (y += cell) {
        var x: f64 = 0;
        while (x < width) : (x += cell) {
            const odd = @as(i32, @intFromFloat(@floor(x / cell))) + @as(i32, @intFromFloat(@floor(y / cell)));
            if (@mod(odd, 2) == 0) {
                c.CGContextSetRGBFillColor(ctx, 0.16, 0.17, 0.19, 1.0);
            } else {
                c.CGContextSetRGBFillColor(ctx, 0.20, 0.21, 0.24, 1.0);
            }
            c.CGContextFillRect(ctx, c.CGRectMake(x, y, cell, cell));
        }
    }
}

fn drawBackgroundImage(ctx: c.CGContextRef, width: f64, height: f64, bg: state_mod.ImageBuffer) void {
    const colorspace = c.CGColorSpaceCreateDeviceRGB();
    if (colorspace == null) return;
    defer c.CGColorSpaceRelease(colorspace);

    const provider = c.CGDataProviderCreateWithData(null, bg.pixels.ptr, bg.pixels.len, null);
    if (provider == null) return;
    defer c.CGDataProviderRelease(provider);

    const bitmap_info: c.CGBitmapInfo = c.kCGBitmapByteOrder32Big | c.kCGImageAlphaPremultipliedLast;
    const image = c.CGImageCreate(
        bg.width,
        bg.height,
        8,
        32,
        bg.width * 4,
        colorspace,
        bitmap_info,
        provider,
        null,
        true,
        c.kCGRenderingIntentDefault,
    );
    if (image == null) return;
    defer c.CGImageRelease(image);

    const image_w = @as(f64, @floatFromInt(bg.width));
    const image_h = @as(f64, @floatFromInt(bg.height));
    const ratio = @min(width / image_w, height / image_h);
    const fitted_w = image_w * ratio;
    const fitted_h = image_h * ratio;

    const x = (width - fitted_w) / 2.0;
    const y = (height - fitted_h) / 2.0;

    c.CGContextSaveGState(ctx);
    c.CGContextSetAlpha(ctx, 0.96);
    c.CGContextDrawImage(ctx, c.CGRectMake(x, y, fitted_w, fitted_h), image);
    c.CGContextRestoreGState(ctx);
}

fn drawSelectionOverlay(state: *const state_mod.AppState, ctx: c.CGContextRef) void {
    const bounds = state.getSelectedBounds() orelse return;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);

    var dash = [_]f64{ 6.0, 4.0 };
    c.CGContextSetLineDash(ctx, 0, &dash, dash.len);
    c.CGContextSetLineWidth(ctx, 1.5);
    c.CGContextSetRGBStrokeColor(ctx, 0.15, 0.39, 0.92, 1.0);

    c.CGContextStrokeRect(
        ctx,
        c.CGRectMake(bounds.min_x, bounds.min_y, bounds.max_x - bounds.min_x, bounds.max_y - bounds.min_y),
    );

    c.CGContextSetLineDash(ctx, 0, null, 0);

    for (math.handle_order) |handle| {
        const center = math.handleCenter(bounds, handle);
        const rect = c.CGRectMake(
            center.x - HANDLE_SIZE / 2.0,
            center.y - HANDLE_SIZE / 2.0,
            HANDLE_SIZE,
            HANDLE_SIZE,
        );

        c.CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
        c.CGContextFillRect(ctx, rect);

        c.CGContextSetLineWidth(ctx, 1.0);
        c.CGContextSetRGBStrokeColor(ctx, 0.15, 0.39, 0.92, 1.0);
        c.CGContextStrokeRect(ctx, rect);
    }
}

fn drawShape(ctx: c.CGContextRef, shape: shapes.Shape) void {
    switch (shape) {
        .freehand => |freehand| drawFreehand(ctx, freehand),
        .circle => |circle| drawCircle(ctx, circle),
        .rect => |rect_shape| drawRect(ctx, rect_shape),
        .arrow => |arrow| drawArrow(ctx, arrow),
        .line => |line| drawLine(ctx, line),
        .text => |text_shape| drawText(ctx, text_shape),
    }
}

fn applyStroke(ctx: c.CGContextRef, color: [4]f32, width: f64) void {
    c.CGContextSetLineWidth(ctx, width);
    c.CGContextSetLineCap(ctx, c.kCGLineCapRound);
    c.CGContextSetLineJoin(ctx, c.kCGLineJoinRound);
    c.CGContextSetRGBStrokeColor(ctx, color[0], color[1], color[2], color[3]);
}

fn normalizedRect(origin: shapes.Point, width: f64, height: f64) c.CGRect {
    const x = if (width >= 0) origin.x else origin.x + width;
    const y = if (height >= 0) origin.y else origin.y + height;
    const w = @abs(width);
    const h = @abs(height);
    return c.CGRectMake(x, y, w, h);
}

fn drawFreehand(ctx: c.CGContextRef, freehand: shapes.Freehand) void {
    if (freehand.points.items.len < 2) return;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);

    applyStroke(ctx, freehand.base.color, freehand.base.stroke_width);

    const first = freehand.points.items[0];
    c.CGContextBeginPath(ctx);
    c.CGContextMoveToPoint(ctx, first.x, first.y);

    for (freehand.points.items[1..]) |point| {
        c.CGContextAddLineToPoint(ctx, point.x, point.y);
    }

    c.CGContextStrokePath(ctx);
}

fn drawCircle(ctx: c.CGContextRef, circle: shapes.Circle) void {
    if (circle.radius_x <= 0 and circle.radius_y <= 0) return;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);

    applyStroke(ctx, circle.base.color, circle.base.stroke_width);

    const rect = c.CGRectMake(
        circle.center.x - circle.radius_x,
        circle.center.y - circle.radius_y,
        circle.radius_x * 2.0,
        circle.radius_y * 2.0,
    );

    c.CGContextBeginPath(ctx);
    c.CGContextAddEllipseInRect(ctx, rect);
    c.CGContextStrokePath(ctx);
}

fn drawRect(ctx: c.CGContextRef, rect_shape: shapes.Rect) void {
    if (@abs(rect_shape.width) <= 0 and @abs(rect_shape.height) <= 0) return;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);

    applyStroke(ctx, rect_shape.base.color, rect_shape.base.stroke_width);

    const rect = normalizedRect(rect_shape.origin, rect_shape.width, rect_shape.height);
    c.CGContextStrokeRect(ctx, rect);
}

fn drawLine(ctx: c.CGContextRef, line: shapes.Line) void {
    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);

    applyStroke(ctx, line.base.color, line.base.stroke_width);

    c.CGContextBeginPath(ctx);
    c.CGContextMoveToPoint(ctx, line.start.x, line.start.y);
    c.CGContextAddLineToPoint(ctx, line.end.x, line.end.y);
    c.CGContextStrokePath(ctx);
}

fn drawArrow(ctx: c.CGContextRef, arrow: shapes.Arrow) void {
    const dx = arrow.end.x - arrow.start.x;
    const dy = arrow.end.y - arrow.start.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= 0.001) return;

    const ux = dx / len;
    const uy = dy / len;
    const pointer_len = arrow.base.stroke_width * 3.0;
    const pointer_width = arrow.base.stroke_width * 1.8;

    const lx = arrow.end.x - ux * pointer_len - uy * pointer_width;
    const ly = arrow.end.y - uy * pointer_len + ux * pointer_width;
    const rx = arrow.end.x - ux * pointer_len + uy * pointer_width;
    const ry = arrow.end.y - uy * pointer_len - ux * pointer_width;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);

    applyStroke(ctx, arrow.base.color, arrow.base.stroke_width);

    c.CGContextBeginPath(ctx);
    c.CGContextMoveToPoint(ctx, arrow.start.x, arrow.start.y);
    c.CGContextAddLineToPoint(ctx, arrow.end.x, arrow.end.y);
    c.CGContextStrokePath(ctx);

    c.CGContextSetRGBFillColor(
        ctx,
        arrow.base.color[0],
        arrow.base.color[1],
        arrow.base.color[2],
        arrow.base.color[3],
    );
    c.CGContextBeginPath(ctx);
    c.CGContextMoveToPoint(ctx, arrow.end.x, arrow.end.y);
    c.CGContextAddLineToPoint(ctx, lx, ly);
    c.CGContextAddLineToPoint(ctx, rx, ry);
    c.CGContextClosePath(ctx);
    c.CGContextFillPath(ctx);
}

fn drawText(ctx: c.CGContextRef, text_shape: shapes.Text) void {
    if (text_shape.text.len == 0) return;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);

    c.CGContextSetRGBFillColor(
        ctx,
        text_shape.base.color[0],
        text_shape.base.color[1],
        text_shape.base.color[2],
        text_shape.base.color[3],
    );

    const font_name: [*:0]const u8 = "Helvetica";
    c.CGContextSelectFont(ctx, font_name, text_shape.font_size, c.kCGEncodingMacRoman);
    c.CGContextShowTextAtPoint(
        ctx,
        text_shape.position.x,
        text_shape.position.y + text_shape.font_size,
        text_shape.text.ptr,
        text_shape.text.len,
    );
}
