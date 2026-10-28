#pragma once

// C interface between the Zig app logic (main.zig and friends) and the
// Objective-C AppKit shim (shim.m).
//
// Coordinate spaces:
//   view  — points inside the canvas NSView, origin top-left, y down.
//   doc   — pixels of the background image, origin top-left, y down. Shapes are
//           stored in doc space so that annotations stay attached to the image
//           when the window resizes and export 1:1 with the image.
// Every sm_* input function takes view coordinates; Zig converts.

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct SmAppState SmAppState;

typedef struct SmModifiers {
    uint8_t command;
    uint8_t shift;
    uint8_t option;
    uint8_t control;
} SmModifiers;

typedef struct SmToolbarModel {
    uint8_t selected_tool;
    uint8_t can_undo;
    uint8_t can_redo;
    uint8_t has_background;
    uint8_t has_selection;
    uint8_t has_shapes;
    uint8_t reserved[2];
} SmToolbarModel;

typedef struct SmTextStyle {
    float r;
    float g;
    float b;
    float a;
    double stroke_width; // view points, the user's preference
    double font_size;    // view points
} SmTextStyle;

// RGBA8, premultiplied, top-down rows, width * 4 bytes per row.
typedef struct SmImageBuffer {
    uint8_t *pixels;
    size_t width;
    size_t height;
    double point_width;  // size in points, used for DPI metadata
    double point_height;
    CGColorSpaceRef colorspace; // may be NULL (sRGB is then used)
} SmImageBuffer;

// Describes a text shape for the native inline editor.
typedef struct SmTextEdit {
    uint64_t shape_id; // 0 when creating a new shape
    double view_x;     // top-left of the text in view coordinates
    double view_y;
    double font_px;    // font size in view points
    float r;
    float g;
    float b;
    float a;
    size_t text_len;   // bytes copied into the caller's buffer
} SmTextEdit;

// ---- Implemented in Zig, called by the shim ---------------------------------

SmAppState *sm_app_create(void);
void sm_app_destroy(SmAppState *state);

void sm_on_mouse_down(SmAppState *state, double x, double y, SmModifiers modifiers);
void sm_on_mouse_drag(SmAppState *state, double x, double y, SmModifiers modifiers);
void sm_on_mouse_up(SmAppState *state, double x, double y, SmModifiers modifiers);
// Returns true when the key was consumed.
bool sm_on_key_down(SmAppState *state, uint16_t key_code, SmModifiers modifiers);

// Draws the canvas into a flipped (y down) context of width x height points.
// scale is the backing scale factor of the window.
void sm_draw(SmAppState *state, CGContextRef ctx, double width, double height, double scale);

bool sm_paste_from_clipboard(SmAppState *state);
bool sm_copy_to_clipboard(SmAppState *state);
bool sm_undo(SmAppState *state);
bool sm_redo(SmAppState *state);
bool sm_delete_selected(SmAppState *state);
bool sm_clear_shapes(SmAppState *state);

void sm_set_tool(SmAppState *state, uint32_t tool);
void sm_set_color(SmAppState *state, float r, float g, float b, float a);
void sm_set_stroke_width(SmAppState *state, double stroke_width);
// While true, redraws use the full-size background instead of rebuilding the
// pre-scaled cache on every frame of a window resize.
void sm_set_live_resize(SmAppState *state, bool live);

void sm_get_toolbar_model(SmAppState *state, SmToolbarModel *out_model);
void sm_get_text_style(SmAppState *state, SmTextStyle *out_style);
bool sm_get_background_point_size(SmAppState *state, double *out_width, double *out_height);

// Text editing. Hit test finds an existing text shape under a view point and
// copies its text into buf (up to cap bytes). new_at describes a fresh shape at
// a view point. commit replaces the text of shape_id, or adds a new shape when
// shape_id is 0; committing empty text to an existing shape deletes it.
bool sm_text_hit_test(SmAppState *state, double view_x, double view_y, SmTextEdit *out_edit, uint8_t *buf, size_t cap);
void sm_text_new_at(SmAppState *state, double view_x, double view_y, SmTextEdit *out_edit);
bool sm_text_commit(SmAppState *state, uint64_t shape_id, double view_x, double view_y, const uint8_t *text, size_t text_len);

// ---- Implemented in the shim, called by Zig ---------------------------------

// Reads the clipboard image at full pixel resolution as a retained CGImage.
bool sm_platform_read_clipboard_image(CGImageRef *out_image, size_t *out_width, size_t *out_height,
                                      double *out_point_width, double *out_point_height);
bool sm_platform_write_clipboard_rgba(const SmImageBuffer *image);
// True when the pasteboard changed since SnapMark last read or wrote it.
bool sm_platform_clipboard_changed(void);
void sm_platform_measure_text(const uint8_t *text, size_t text_len, double font_size, double *out_width, double *out_height);
// x, y is the top-left corner of the text in the context's (flipped) user space.
void sm_platform_draw_text(CGContextRef ctx, double x, double y, const uint8_t *text, size_t text_len,
                           double font_size, float r, float g, float b, float a);
void sm_platform_invalidate(void);
void sm_platform_background_changed(void);
void sm_platform_hide_window(void);
void sm_platform_run_app(void);
