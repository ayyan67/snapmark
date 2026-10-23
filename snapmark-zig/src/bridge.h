#pragma once

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
    uint8_t reserved;
} SmToolbarModel;

typedef struct SmTextStyle {
    float r;
    float g;
    float b;
    float a;
    double stroke_width;
    double font_size;
} SmTextStyle;

typedef struct SmImageBuffer {
    uint8_t *pixels;
    size_t width;
    size_t height;
} SmImageBuffer;

SmAppState *sm_app_create(void);
void sm_app_destroy(SmAppState *state);
void sm_on_mouse_down(SmAppState *state, double x, double y, SmModifiers modifiers);
void sm_on_mouse_drag(SmAppState *state, double x, double y, SmModifiers modifiers);
void sm_on_mouse_up(SmAppState *state, double x, double y, SmModifiers modifiers);
void sm_on_key_down(SmAppState *state, uint16_t key_code, SmModifiers modifiers);
void sm_draw(SmAppState *state, CGContextRef ctx, double width, double height, double scale);
bool sm_add_text(SmAppState *state, double x, double y, const uint8_t *text, size_t text_len);
void sm_get_text_style(SmAppState *state, SmTextStyle *out_style);
void sm_set_color(SmAppState *state, float r, float g, float b, float a);
void sm_set_stroke_width(SmAppState *state, double stroke_width);
bool sm_clear_document(SmAppState *state);
bool sm_paste_from_clipboard(SmAppState *state);
bool sm_copy_to_clipboard(SmAppState *state);
void sm_get_toolbar_model(SmAppState *state, SmToolbarModel *out_model);
void sm_toolbar_click(SmAppState *state, uint32_t action_id);

bool sm_platform_read_clipboard_rgba(SmImageBuffer *out_image);
bool sm_platform_write_clipboard_rgba(const SmImageBuffer *image);
void sm_platform_free(void *ptr);
void sm_platform_invalidate(void);
void sm_platform_hide_window(void);
void sm_platform_run_app(void);
