// Core Graphics rendering. The same code draws the on-screen canvas and the
// clipboard export; the only difference is the transform set up in `draw`.
const c = @import("c.zig").c;
const math = @import("math.zig");
const shapes = @import("shapes.zig");
const state_mod = @import("state.zig");

const HANDLE_SIZE: f64 = 8.0;

pub const Mode = enum {
    // Fit the document into the canvas, draw UI chrome (selection, hint).
    screen,
    // Draw the document 1:1 at its own pixel size, nothing else.
    clipboard,
};

pub fn draw(state: *state_mod.AppState, ctx: c.CGContextRef, width: f64, height: f64, mode: Mode) void {
    if (ctx == null) return;

    switch (mode) {
        .screen => drawScreen(state, ctx, width, height),
        .clipboard => drawClipboard(state, ctx, width, height),
    }
}

fn drawScreen(state: *state_mod.AppState, ctx: c.CGContextRef, width: f64, height: f64) void {
    c.CGContextSetRGBFillColor(ctx, 0.09, 0.10, 0.12, 1.0);
    c.CGContextFillRect(ctx, c.CGRectMake(0, 0, width, height));

    const view = state.view;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);
    c.CGContextTranslateCTM(ctx, view.offset_x, view.offset_y);
    c.CGContextScaleCTM(ctx, view.scale, view.scale);

    if (state.background) |bg| {
        const bw: f64 = @floatFromInt(bg.width);
        const bh: f64 = @floatFromInt(bg.height);
        const image = if (state.live_resize) bg.image else state.scaledBackgroundImage(view.scale * state.backing_scale);

        // Clip annotations to the image so the screen matches what Copy exports.
        c.CGContextSaveGState(ctx);
        c.CGContextClipToRect(ctx, c.CGRectMake(0, 0, bw, bh));
        drawImageFlipped(ctx, image, bw, bh);
        drawShapes(state, ctx);
        c.CGContextRestoreGState(ctx);
    } else {
        if (state.shape_list.items.len == 0 and state.temp_shape == null) {
            drawEmptyHint(ctx, width, height);
        }
        drawShapes(state, ctx);
    }

    if (state.tool == .select) {
        drawSelectionOverlay(state, ctx, 1.0 / view.scale);
    }
}

fn drawClipboard(state: *state_mod.AppState, ctx: c.CGContextRef, width: f64, height: f64) void {
    if (state.background) |bg| {
        drawImageFlipped(ctx, bg.image, @floatFromInt(bg.width), @floatFromInt(bg.height));
    } else {
        c.CGContextSetRGBFillColor(ctx, 0.09, 0.10, 0.12, 1.0);
        c.CGContextFillRect(ctx, c.CGRectMake(0, 0, width, height));
    }
    drawShapes(state, ctx);
}

fn drawShapes(state: *const state_mod.AppState, ctx: c.CGContextRef) void {
    for (state.shape_list.items) |shape| {
        // The inline editor shows this text while it is being edited.
        if (state.editing_text_id) |editing| {
            if (shape.id() == editing) continue;
        }
        drawShape(ctx, shape);
    }
    if (state.temp_shape) |shape| drawShape(ctx, shape);
}

// Draws a CGImage upright into a y-down context.
fn drawImageFlipped(ctx: c.CGContextRef, image: c.CGImageRef, width: f64, height: f64) void {
    if (image == null) return;
    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);
    c.CGContextTranslateCTM(ctx, 0, height);
    c.CGContextScaleCTM(ctx, 1, -1);
    c.CGContextDrawImage(ctx, c.CGRectMake(0, 0, width, height), image);
}

fn drawEmptyHint(ctx: c.CGContextRef, width: f64, height: f64) void {
    const title = "Paste a screenshot";
    const subtitle = "\u{2318}V here, or \u{2318}\u{21E7}A from anywhere";
    const title_size: f64 = 18.0;
    const subtitle_size: f64 = 13.0;

    var tw: f64 = 0;
    var th: f64 = 0;
    c.sm_platform_measure_text(title.ptr, title.len, title_size, &tw, &th);
    var sw: f64 = 0;
    var sh: f64 = 0;
    c.sm_platform_measure_text(subtitle.ptr, subtitle.len, subtitle_size, &sw, &sh);

    const total = th + 8 + sh;
    const top = (height - total) / 2.0;
    c.sm_platform_draw_text(ctx, (width - tw) / 2.0, top, title.ptr, title.len, title_size, 0.80, 0.82, 0.86, 1.0);
    c.sm_platform_draw_text(ctx, (width - sw) / 2.0, top + th + 8, subtitle.ptr, subtitle.len, subtitle_size, 0.50, 0.53, 0.58, 1.0);
}

fn drawSelectionOverlay(state: *const state_mod.AppState, ctx: c.CGContextRef, ui_scale: f64) void {
    const bounds = state.getSelectedBounds() orelse return;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);

    var dash = [_]f64{ 6.0 * ui_scale, 4.0 * ui_scale };
    c.CGContextSetLineDash(ctx, 0, &dash, dash.len);
    c.CGContextSetLineWidth(ctx, 1.5 * ui_scale);
    c.CGContextSetRGBStrokeColor(ctx, 0.25, 0.50, 1.0, 1.0);
    c.CGContextStrokeRect(ctx, c.CGRectMake(bounds.min_x, bounds.min_y, bounds.width(), bounds.height()));
    c.CGContextSetLineDash(ctx, 0, null, 0);

    const handle = HANDLE_SIZE * ui_scale;
    c.CGContextSetLineWidth(ctx, 1.0 * ui_scale);
    for (math.handle_order) |which| {
        const center = math.handleCenter(bounds, which);
        const rect = c.CGRectMake(center.x - handle / 2.0, center.y - handle / 2.0, handle, handle);
        c.CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
        c.CGContextFillRect(ctx, rect);
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

fn drawFreehand(ctx: c.CGContextRef, freehand: shapes.Freehand) void {
    const pts = freehand.points.items;
    if (pts.len < 2) return;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);
    applyStroke(ctx, freehand.base.color, freehand.base.stroke_width);

    c.CGContextBeginPath(ctx);
    c.CGContextMoveToPoint(ctx, pts[0].x, pts[0].y);

    // Catmull-Rom spline through the sampled points, as cubic Beziers.
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        const p0 = pts[if (i == 0) 0 else i - 1];
        const p1 = pts[i];
        const p2 = pts[i + 1];
        const p3 = pts[if (i + 2 < pts.len) i + 2 else pts.len - 1];
        const c1x = p1.x + (p2.x - p0.x) / 6.0;
        const c1y = p1.y + (p2.y - p0.y) / 6.0;
        const c2x = p2.x - (p3.x - p1.x) / 6.0;
        const c2y = p2.y - (p3.y - p1.y) / 6.0;
        c.CGContextAddCurveToPoint(ctx, c1x, c1y, c2x, c2y, p2.x, p2.y);
    }

    c.CGContextStrokePath(ctx);
}

fn drawCircle(ctx: c.CGContextRef, circle: shapes.Circle) void {
    if (circle.radius_x <= 0 and circle.radius_y <= 0) return;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);
    applyStroke(ctx, circle.base.color, circle.base.stroke_width);

    c.CGContextBeginPath(ctx);
    c.CGContextAddEllipseInRect(ctx, c.CGRectMake(
        circle.center.x - circle.radius_x,
        circle.center.y - circle.radius_y,
        circle.radius_x * 2.0,
        circle.radius_y * 2.0,
    ));
    c.CGContextStrokePath(ctx);
}

fn drawRect(ctx: c.CGContextRef, rect_shape: shapes.Rect) void {
    if (rect_shape.width == 0 and rect_shape.height == 0) return;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);
    applyStroke(ctx, rect_shape.base.color, rect_shape.base.stroke_width);

    const x = @min(rect_shape.origin.x, rect_shape.origin.x + rect_shape.width);
    const y = @min(rect_shape.origin.y, rect_shape.origin.y + rect_shape.height);
    c.CGContextStrokeRect(ctx, c.CGRectMake(x, y, @abs(rect_shape.width), @abs(rect_shape.height)));
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
    const sw = arrow.base.stroke_width;
    const head_len = @min(len, sw * 3.5);
    const head_half = sw * 1.75;

    // The shaft stops short of the tip so the round cap stays inside the head.
    const shaft_x = arrow.end.x - ux * head_len * 0.6;
    const shaft_y = arrow.end.y - uy * head_len * 0.6;
    const base_x = arrow.end.x - ux * head_len;
    const base_y = arrow.end.y - uy * head_len;
    const lx = base_x - uy * head_half;
    const ly = base_y + ux * head_half;
    const rx = base_x + uy * head_half;
    const ry = base_y - ux * head_half;

    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);
    applyStroke(ctx, arrow.base.color, sw);

    c.CGContextBeginPath(ctx);
    c.CGContextMoveToPoint(ctx, arrow.start.x, arrow.start.y);
    c.CGContextAddLineToPoint(ctx, shaft_x, shaft_y);
    c.CGContextStrokePath(ctx);

    c.CGContextSetRGBFillColor(ctx, arrow.base.color[0], arrow.base.color[1], arrow.base.color[2], arrow.base.color[3]);
    c.CGContextBeginPath(ctx);
    c.CGContextMoveToPoint(ctx, arrow.end.x, arrow.end.y);
    c.CGContextAddLineToPoint(ctx, lx, ly);
    c.CGContextAddLineToPoint(ctx, rx, ry);
    c.CGContextClosePath(ctx);
    c.CGContextFillPath(ctx);
}

fn drawText(ctx: c.CGContextRef, text_shape: shapes.Text) void {
    if (text_shape.text.len == 0) return;
    c.sm_platform_draw_text(
        ctx,
        text_shape.position.x,
        text_shape.position.y,
        text_shape.text.ptr,
        text_shape.text.len,
        text_shape.font_size,
        text_shape.base.color[0],
        text_shape.base.color[1],
        text_shape.base.color[2],
        text_shape.base.color[3],
    );
}
