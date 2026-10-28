// AppKit side of SnapMark: window, toolbar, canvas view, menus, pasteboard,
// status item, global hotkey and the inline text editor. App logic and
// rendering live in Zig; see bridge.h for the interface.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreText/CoreText.h>

#import "bridge.h"

// ---- Globals ------------------------------------------------------------------

static SmAppState *g_state = NULL;
static NSWindow *g_window = nil;
static NSView *g_toolbar_view = nil;
static NSView *g_canvas_view = nil;
static id g_app_delegate = nil;
static NSStatusItem *g_status_item = nil;

static NSButton *g_tool_buttons[8] = {nil};
static NSButton *g_color_buttons[6] = {nil};
static NSButton *g_stroke_buttons[3] = {nil};
static NSButton *g_undo_button = nil;
static NSButton *g_redo_button = nil;
static NSButton *g_clear_button = nil;
static NSButton *g_copy_button = nil;
static SmToolbarModel g_last_model;
static SmTextStyle g_last_style;
static BOOL g_toolbar_valid = NO;
static NSUInteger g_copy_feedback_token = 0;

static NSTextField *g_text_editor = nil;
static id g_text_key_monitor = nil;
static id g_text_end_observer = nil;
static id g_text_change_observer = nil;
static uint64_t g_text_shape_id = 0;
static NSPoint g_text_origin = {0.0, 0.0};
static NSString *g_text_original = nil;
static CGFloat g_text_font_px = 20.0;
static BOOL g_text_edit_closing = NO;

static EventHotKeyRef g_hotkey_ref = NULL;
static EventHandlerRef g_hotkey_handler_ref = NULL;

// changeCount of the pasteboard the last time SnapMark read or wrote it.
static NSInteger g_seen_change_count = -1;

enum {
    kSnapMarkHotKeySignature = 'SMHK',
    kSnapMarkHotKeyId = 1,
};

enum {
    kToolSelect = 1,
    kToolText = 7,
};

static const CGFloat kToolbarTop = 8.0;
static const CGFloat kToolbarHeight = 40.0;
static const CGFloat kCanvasGap = 4.0;
static const CGFloat kCanvasPadding = 12.0; // matches CANVAS_PADDING in state.zig
static const CGFloat kMinContentWidth = 760.0;
static const CGFloat kMinContentHeight = 420.0;

static const float kPresetColors[6][4] = {
    {1.00f, 0.20f, 0.20f, 1.00f}, // red
    {0.25f, 0.50f, 1.00f, 1.00f}, // blue
    {0.20f, 0.75f, 0.35f, 1.00f}, // green
    {1.00f, 0.78f, 0.20f, 1.00f}, // yellow
    {0.08f, 0.08f, 0.10f, 1.00f}, // black
    {1.00f, 1.00f, 1.00f, 1.00f}, // white
};
static NSString *const kColorNames[6] = {@"Red", @"Blue", @"Green", @"Yellow", @"Black", @"White"};

static const double kStrokeWidths[3] = {2.0, 4.0, 8.0};

static void sm_text_edit_finish(BOOL commit);
static void sm_refresh_toolbar(BOOL force);

// ---- Small helpers ------------------------------------------------------------

static SmModifiers sm_modifiers_from_event(NSEvent *event) {
    const NSEventModifierFlags flags = event.modifierFlags;
    SmModifiers modifiers;
    modifiers.command = (flags & NSEventModifierFlagCommand) != 0;
    modifiers.shift = (flags & NSEventModifierFlagShift) != 0;
    modifiers.option = (flags & NSEventModifierFlagOption) != 0;
    modifiers.control = (flags & NSEventModifierFlagControl) != 0;
    return modifiers;
}

static NSString *sm_string(const uint8_t *bytes, size_t len) {
    if (bytes == NULL || len == 0) return @"";
    NSString *s = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    return s ?: @"";
}

static NSFont *sm_annotation_font(CGFloat size) {
    return [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
}

static uint8_t sm_current_tool(void) {
    if (g_state == NULL) return 0;
    SmToolbarModel model = {0};
    sm_get_toolbar_model(g_state, &model);
    return model.selected_tool;
}

// ---- Window -------------------------------------------------------------------

static void sm_show_window(void) {
    if (g_window == nil) return;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [g_window makeKeyAndOrderFront:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    if (g_text_editor == nil) {
        [g_window makeFirstResponder:g_canvas_view];
    }
}

static void sm_show_window_and_paste(void) {
    if (g_state == NULL) return;
    sm_text_edit_finish(YES);
    // Paste first so the window is already sized for the image when it appears.
    sm_paste_from_clipboard(g_state);
    sm_show_window();
}

void sm_platform_hide_window(void) {
    if (g_window == nil) return;
    sm_text_edit_finish(YES);
    [g_window orderOut:nil];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

// Sizes the window so a pasted image shows at its own point size when the
// screen has room, keeping the window centred where it was.
void sm_platform_background_changed(void) {
    if (g_window == nil || g_state == NULL) return;

    double point_w = 0, point_h = 0;
    if (!sm_get_background_point_size(g_state, &point_w, &point_h)) return;

    NSScreen *screen = g_window.screen ?: NSScreen.mainScreen;
    const NSRect visible = screen.visibleFrame;
    const CGFloat chrome = kToolbarTop + kToolbarHeight + kCanvasGap;

    const NSSize content = NSMakeSize(MAX(point_w + 2.0 * kCanvasPadding, kMinContentWidth),
                                      MAX(point_h + 2.0 * kCanvasPadding + chrome, kMinContentHeight));
    NSRect frame = [g_window frameRectForContentRect:NSMakeRect(0, 0, content.width, content.height)];
    frame.size.width = MIN(frame.size.width, floor(visible.size.width * 0.94));
    frame.size.height = MIN(frame.size.height, floor(visible.size.height * 0.94));

    const NSRect anchor = g_window.isVisible ? g_window.frame : visible;
    frame.origin.x = NSMidX(anchor) - frame.size.width / 2.0;
    frame.origin.y = NSMidY(anchor) - frame.size.height / 2.0;
    frame.origin.x = MAX(NSMinX(visible), MIN(frame.origin.x, NSMaxX(visible) - frame.size.width));
    frame.origin.y = MAX(NSMinY(visible), MIN(frame.origin.y, NSMaxY(visible) - frame.size.height));

    [g_window setFrame:NSIntegralRect(frame) display:g_window.isVisible];
}

void sm_platform_invalidate(void) {
    sm_refresh_toolbar(NO);
    [g_canvas_view setNeedsDisplay:YES];
}

// ---- Toolbar ------------------------------------------------------------------

static NSImage *sm_symbol(NSString *name, NSString *description) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
    if (image == nil) return nil;
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:14.0
                                                                                         weight:NSFontWeightMedium];
    return [image imageWithSymbolConfiguration:config] ?: image;
}

static NSImage *sm_stroke_image(CGFloat width) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(20, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = width;
        path.lineCapStyle = NSLineCapStyleRound;
        [path moveToPoint:NSMakePoint(4.0, 9.0)];
        [path lineToPoint:NSMakePoint(16.0, 9.0)];
        [NSColor.blackColor setStroke];
        [path stroke];
        return YES;
    }];
    image.template = YES;
    return image;
}

static NSButton *sm_icon_button(NSImage *image, NSString *fallback, NSString *tip, NSInteger tag, id target, SEL action) {
    NSButton *button = image != nil
        ? [NSButton buttonWithImage:image target:target action:action]
        : [NSButton buttonWithTitle:fallback target:target action:action];
    button.tag = tag;
    button.toolTip = tip;
    button.bordered = NO;
    button.buttonType = NSButtonTypeMomentaryPushIn;
    button.focusRingType = NSFocusRingTypeNone;
    button.contentTintColor = [NSColor colorWithWhite:0.86 alpha:1.0];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.wantsLayer = YES;
    button.layer.cornerRadius = 6.0;
    [button.widthAnchor constraintEqualToConstant:30.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:28.0].active = YES;
    return button;
}

static void sm_style_toggle(NSButton *button, BOOL on) {
    button.layer.backgroundColor = on ? [NSColor colorWithRed:0.25 green:0.50 blue:1.0 alpha:0.95].CGColor
                                      : NSColor.clearColor.CGColor;
    button.contentTintColor = on ? NSColor.whiteColor : [NSColor colorWithWhite:0.86 alpha:1.0];
}

static NSView *sm_make_separator(void) {
    NSView *separator = [[NSView alloc] initWithFrame:NSZeroRect];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.wantsLayer = YES;
    separator.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.16].CGColor;
    [separator.widthAnchor constraintEqualToConstant:1.0].active = YES;
    [separator.heightAnchor constraintEqualToConstant:18.0].active = YES;
    return separator;
}

static BOOL sm_color_matches(const SmTextStyle *style, const float preset[4]) {
    const float eps = 0.02f;
    return fabsf(style->r - preset[0]) <= eps && fabsf(style->g - preset[1]) <= eps &&
           fabsf(style->b - preset[2]) <= eps && fabsf(style->a - preset[3]) <= eps;
}

// Updates button states. Skips all work when nothing the toolbar shows has
// changed, since this runs on every mouse-drag event.
static void sm_refresh_toolbar(BOOL force) {
    if (g_state == NULL || g_toolbar_view == nil) return;

    SmToolbarModel model = {0};
    sm_get_toolbar_model(g_state, &model);
    SmTextStyle style = {0};
    sm_get_text_style(g_state, &style);

    if (!force && g_toolbar_valid &&
        memcmp(&model, &g_last_model, sizeof(model)) == 0 &&
        memcmp(&style, &g_last_style, sizeof(style)) == 0) {
        return;
    }
    const BOOL tool_changed = !g_toolbar_valid || model.selected_tool != g_last_model.selected_tool;
    g_last_model = model;
    g_last_style = style;
    g_toolbar_valid = YES;

    for (uint8_t tool = 1; tool <= 7; tool++) {
        if (g_tool_buttons[tool] != nil) sm_style_toggle(g_tool_buttons[tool], model.selected_tool == tool);
    }
    for (NSInteger i = 0; i < 3; i++) {
        if (g_stroke_buttons[i] != nil) sm_style_toggle(g_stroke_buttons[i], fabs(style.stroke_width - kStrokeWidths[i]) < 0.11);
    }
    for (NSInteger i = 0; i < 6; i++) {
        NSButton *button = g_color_buttons[i];
        if (button == nil) continue;
        const BOOL selected = sm_color_matches(&style, kPresetColors[i]);
        button.layer.borderWidth = selected ? 2.5 : 1.0;
        button.layer.borderColor = selected ? NSColor.whiteColor.CGColor : [NSColor colorWithWhite:1.0 alpha:0.25].CGColor;
    }

    g_undo_button.enabled = model.can_undo != 0;
    g_redo_button.enabled = model.can_redo != 0;
    g_clear_button.enabled = model.has_shapes != 0;
    g_copy_button.enabled = model.has_background != 0 || model.has_shapes != 0;

    if (tool_changed && g_canvas_view != nil) {
        [g_window invalidateCursorRectsForView:g_canvas_view];
    }
}

static void sm_build_toolbar(NSView *container, id target) {
    NSView *toolbar = [[NSView alloc] initWithFrame:NSZeroRect];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.wantsLayer = YES;
    toolbar.layer.backgroundColor = [NSColor colorWithRed:0.14 green:0.15 blue:0.18 alpha:1.0].CGColor;
    toolbar.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.10].CGColor;
    toolbar.layer.borderWidth = 1.0;
    toolbar.layer.cornerRadius = 10.0;
    [container addSubview:toolbar];
    g_toolbar_view = toolbar;

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 3.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbar addSubview:stack];

    struct { NSString *symbol; NSString *fallback; NSString *tip; } tools[7] = {
        {@"cursorarrow", @"Sel", @"Select (1)"},
        {@"scribble", @"Pen", @"Pen (2)"},
        {@"circle", @"O", @"Ellipse (3), hold Shift for a circle"},
        {@"rectangle", @"[]", @"Rectangle (4), hold Shift for a square"},
        {@"arrow.up.right", @"->", @"Arrow (5)"},
        {@"line.diagonal", @"/", @"Line (6)"},
        {@"textformat", @"T", @"Text (7), click existing text to edit it"},
    };
    for (NSInteger i = 0; i < 7; i++) {
        const NSInteger tool_id = i + 1;
        NSButton *button = sm_icon_button(sm_symbol(tools[i].symbol, tools[i].tip), tools[i].fallback,
                                          tools[i].tip, tool_id, target, @selector(toolbarToolClicked:));
        g_tool_buttons[tool_id] = button;
        [stack addArrangedSubview:button];
    }

    [stack addArrangedSubview:sm_make_separator()];

    for (NSInteger i = 0; i < 6; i++) {
        NSButton *button = [NSButton buttonWithTitle:@"" target:target action:@selector(toolbarColorClicked:)];
        button.tag = i;
        button.toolTip = kColorNames[i];
        button.bordered = NO;
        button.focusRingType = NSFocusRingTypeNone;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.wantsLayer = YES;
        button.layer.cornerRadius = 9.0;
        button.layer.backgroundColor = [NSColor colorWithSRGBRed:kPresetColors[i][0] green:kPresetColors[i][1]
                                                            blue:kPresetColors[i][2] alpha:kPresetColors[i][3]].CGColor;
        [button.widthAnchor constraintEqualToConstant:18.0].active = YES;
        [button.heightAnchor constraintEqualToConstant:18.0].active = YES;
        g_color_buttons[i] = button;
        [stack addArrangedSubview:button];
        if (i < 5) [stack setCustomSpacing:6.0 afterView:button];
    }

    [stack addArrangedSubview:sm_make_separator()];

    const CGFloat stroke_icons[3] = {2.0, 3.5, 6.0};
    NSString *stroke_tips[3] = {@"Thin stroke", @"Medium stroke", @"Thick stroke"};
    for (NSInteger i = 0; i < 3; i++) {
        NSButton *button = sm_icon_button(sm_stroke_image(stroke_icons[i]), @"-", stroke_tips[i], i, target,
                                          @selector(toolbarStrokeClicked:));
        g_stroke_buttons[i] = button;
        [stack addArrangedSubview:button];
    }

    [stack addArrangedSubview:sm_make_separator()];

    g_undo_button = sm_icon_button(sm_symbol(@"arrow.uturn.backward", @"Undo"), @"Undo", @"Undo (⌘Z)", 0,
                                   target, @selector(toolbarCommandClicked:));
    g_redo_button = sm_icon_button(sm_symbol(@"arrow.uturn.forward", @"Redo"), @"Redo", @"Redo (⇧⌘Z)", 1,
                                   target, @selector(toolbarCommandClicked:));
    NSButton *paste_button = sm_icon_button(sm_symbol(@"doc.on.clipboard", @"Paste"), @"Paste",
                                            @"Paste screenshot (⌘V)", 2, target, @selector(toolbarCommandClicked:));
    g_clear_button = sm_icon_button(sm_symbol(@"trash", @"Clear"), @"Clear", @"Remove all annotations", 4,
                                    target, @selector(toolbarCommandClicked:));
    [stack addArrangedSubview:g_undo_button];
    [stack addArrangedSubview:g_redo_button];
    [stack addArrangedSubview:paste_button];
    [stack addArrangedSubview:g_clear_button];

    g_copy_button = [NSButton buttonWithTitle:@"Copy" target:target action:@selector(toolbarCommandClicked:)];
    g_copy_button.tag = 3;
    g_copy_button.toolTip = @"Copy the annotated image (⌘C)";
    g_copy_button.bezelStyle = NSBezelStyleRounded;
    g_copy_button.bezelColor = NSColor.controlAccentColor;
    g_copy_button.focusRingType = NSFocusRingTypeNone;
    g_copy_button.translatesAutoresizingMaskIntoConstraints = NO;
    [g_copy_button.widthAnchor constraintEqualToConstant:88.0].active = YES;
    [stack setCustomSpacing:10.0 afterView:g_clear_button];
    [stack addArrangedSubview:g_copy_button];

    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:container.topAnchor constant:kToolbarTop],
        [toolbar.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [toolbar.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:8.0],
        [toolbar.heightAnchor constraintEqualToConstant:kToolbarHeight],
        [stack.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor constant:8.0],
        [stack.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor constant:-8.0],
        [stack.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
    ]];
}

static void sm_flash_copied(void) {
    if (g_copy_button == nil) return;
    const NSUInteger token = ++g_copy_feedback_token;
    g_copy_button.title = @"Copied ✓";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token == g_copy_feedback_token) g_copy_button.title = @"Copy";
    });
}

// ---- Menus, status item, hotkey -------------------------------------------------

static void sm_build_main_menu(void) {
    NSMenu *main_menu = [[NSMenu alloc] init];

    NSMenuItem *app_item = [[NSMenuItem alloc] init];
    NSMenu *app_menu = [[NSMenu alloc] initWithTitle:@"SnapMark"];
    [app_menu addItemWithTitle:@"Hide Window" action:@selector(performClose:) keyEquivalent:@"w"];
    [app_menu addItem:[NSMenuItem separatorItem]];
    [app_menu addItemWithTitle:@"Quit SnapMark" action:@selector(terminate:) keyEquivalent:@"q"];
    app_item.submenu = app_menu;
    [main_menu addItem:app_item];

    NSMenuItem *edit_item = [[NSMenuItem alloc] init];
    NSMenu *edit_menu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit_menu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [edit_menu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit_menu addItem:[NSMenuItem separatorItem]];
    [edit_menu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit_menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit_menu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit_menu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    edit_item.submenu = edit_menu;
    [main_menu addItem:edit_item];

    NSApp.mainMenu = main_menu;
}

static void sm_setup_status_item(id target) {
    g_status_item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    NSStatusBarButton *button = g_status_item.button;
    if (button == nil) return;
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"scribble.variable" accessibilityDescription:@"SnapMark"]
                        ?: [NSImage imageWithSystemSymbolName:@"scribble" accessibilityDescription:@"SnapMark"];
    if (icon != nil) {
        icon.template = YES;
        button.image = icon;
    } else {
        button.title = @"SM";
    }
    button.toolTip = @"SnapMark: open and paste the clipboard (⌘⇧A)";
    button.target = target;
    button.action = @selector(statusItemClicked:);
}

static OSStatus sm_hotkey_handler(EventHandlerCallRef next_handler, EventRef event, void *user_data) {
    (void)next_handler;
    (void)user_data;
    EventHotKeyID hotkey_id = {0};
    const OSStatus status = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                                              sizeof(hotkey_id), NULL, &hotkey_id);
    if (status != noErr) return status;
    if (hotkey_id.signature != kSnapMarkHotKeySignature || hotkey_id.id != kSnapMarkHotKeyId) {
        return eventNotHandledErr;
    }
    sm_show_window_and_paste();
    return noErr;
}

static void sm_setup_global_hotkey(void) {
    EventTypeSpec event_type = {.eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed};
    if (InstallApplicationEventHandler(sm_hotkey_handler, 1, &event_type, NULL, &g_hotkey_handler_ref) != noErr) {
        return;
    }
    EventHotKeyID hotkey_id = {.signature = kSnapMarkHotKeySignature, .id = kSnapMarkHotKeyId};
    if (RegisterEventHotKey(kVK_ANSI_A, cmdKey | shiftKey, hotkey_id, GetApplicationEventTarget(), 0,
                            &g_hotkey_ref) != noErr) {
        RemoveEventHandler(g_hotkey_handler_ref);
        g_hotkey_handler_ref = NULL;
    }
}

static void sm_teardown_global_hotkey(void) {
    if (g_hotkey_ref != NULL) {
        UnregisterEventHotKey(g_hotkey_ref);
        g_hotkey_ref = NULL;
    }
    if (g_hotkey_handler_ref != NULL) {
        RemoveEventHandler(g_hotkey_handler_ref);
        g_hotkey_handler_ref = NULL;
    }
}

// ---- Inline text editor -----------------------------------------------------------

static void sm_text_edit_resize(void) {
    if (g_text_editor == nil) return;
    double w = 0, h = 0;
    NSData *utf8 = [(g_text_editor.stringValue ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    sm_platform_measure_text(utf8.bytes, utf8.length, g_text_font_px, &w, &h);
    NSRect frame = g_text_editor.frame;
    frame.size.width = MAX(200.0, w + g_text_font_px * 2.0);
    g_text_editor.frame = frame;
}

// Opens the editor on existing text under the point, or (when allow_new) for
// a new text shape there. Returns NO when nothing was opened.
static BOOL sm_text_edit_begin(NSPoint point, BOOL allow_new) {
    if (g_state == NULL || g_canvas_view == nil) return NO;
    sm_text_edit_finish(YES);

    static uint8_t buffer[65536];
    SmTextEdit edit = {0};
    NSString *initial = @"";
    if (sm_text_hit_test(g_state, point.x, point.y, &edit, buffer, sizeof(buffer))) {
        initial = sm_string(buffer, MIN(edit.text_len, sizeof(buffer)));
    } else if (allow_new) {
        sm_text_new_at(g_state, point.x, point.y, &edit);
    } else {
        return NO;
    }

    g_text_shape_id = edit.shape_id;
    g_text_origin = NSMakePoint(edit.view_x, edit.view_y);
    g_text_original = initial;
    g_text_font_px = edit.font_px > 1.0 ? edit.font_px : 20.0;

    // NSTextField insets its text by the line fragment padding (2 pt).
    const NSRect frame = NSMakeRect(edit.view_x - 2.0, edit.view_y, 200.0, ceil(g_text_font_px * 1.3) + 2.0);
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.editable = YES;
    field.selectable = YES;
    field.bezeled = NO;
    field.bordered = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.usesSingleLineMode = YES;
    field.cell.scrollable = YES;
    field.font = sm_annotation_font(g_text_font_px);
    field.textColor = [NSColor colorWithSRGBRed:edit.r green:edit.g blue:edit.b alpha:edit.a > 0 ? edit.a : 1.0];
    field.stringValue = initial;
    field.placeholderString = initial.length == 0 ? @"Type…" : nil;
    field.wantsLayer = YES;
    field.layer.borderWidth = 1.0;
    field.layer.borderColor = [NSColor colorWithRed:0.25 green:0.50 blue:1.0 alpha:0.8].CGColor;
    field.layer.cornerRadius = 3.0;
    g_text_editor = field;
    sm_text_edit_resize();

    [g_canvas_view addSubview:field];
    [g_window makeFirstResponder:field];
    NSText *editor = field.currentEditor;
    if (editor != nil) editor.selectedRange = NSMakeRange(initial.length, 0);

    g_text_key_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                               handler:^NSEvent *_Nullable(NSEvent *_Nonnull event) {
        if (g_text_editor == nil) return event;
        if (event.keyCode == kVK_Escape) {
            sm_text_edit_finish(NO);
            return nil;
        }
        if (event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter) {
            sm_text_edit_finish(YES);
            return nil;
        }
        return event;
    }];
    g_text_end_observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSControlTextDidEndEditingNotification object:field queue:nil
                usingBlock:^(NSNotification *_Nonnull note) {
        (void)note;
        sm_text_edit_finish(YES);
    }];
    g_text_change_observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSControlTextDidChangeNotification object:field queue:nil
                usingBlock:^(NSNotification *_Nonnull note) {
        (void)note;
        sm_text_edit_resize();
    }];
    return YES;
}

static void sm_text_edit_finish(BOOL commit) {
    if (g_text_editor == nil || g_text_edit_closing) return;
    g_text_edit_closing = YES;

    NSString *value = commit ? (g_text_editor.stringValue ?: @"") : (g_text_original ?: @"");

    if (g_text_end_observer != nil) [[NSNotificationCenter defaultCenter] removeObserver:g_text_end_observer];
    if (g_text_change_observer != nil) [[NSNotificationCenter defaultCenter] removeObserver:g_text_change_observer];
    if (g_text_key_monitor != nil) [NSEvent removeMonitor:g_text_key_monitor];
    g_text_end_observer = nil;
    g_text_change_observer = nil;
    g_text_key_monitor = nil;

    NSTextField *field = g_text_editor;
    g_text_editor = nil;
    [field removeFromSuperview];

    // An existing shape is always committed (unchanged text is a no-op and it
    // clears the "being edited" flag); a new one only if text was typed.
    if (g_state != NULL && (g_text_shape_id != 0 || value.length > 0)) {
        NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
        sm_text_commit(g_state, g_text_shape_id, g_text_origin.x, g_text_origin.y, utf8.bytes, utf8.length);
    }
    g_text_shape_id = 0;
    g_text_original = nil;

    if (g_canvas_view.window != nil) [g_canvas_view.window makeFirstResponder:g_canvas_view];
    g_text_edit_closing = NO;
    sm_platform_invalidate();
}

// ---- Canvas view -----------------------------------------------------------------

@interface SnapMarkCanvasView : NSView
@end

@implementation SnapMarkCanvasView

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    if (g_state == NULL) {
        [[NSColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0] setFill];
        NSRectFill(self.bounds);
        return;
    }
    const CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 2.0;
    sm_draw(g_state, cg, self.bounds.size.width, self.bounds.size.height, scale);
}

- (void)viewWillStartLiveResize {
    [super viewWillStartLiveResize];
    sm_set_live_resize(g_state, true);
}

- (void)viewDidEndLiveResize {
    [super viewDidEndLiveResize];
    sm_set_live_resize(g_state, false);
    [self setNeedsDisplay:YES];
}

- (void)resetCursorRects {
    const uint8_t tool = sm_current_tool();
    NSCursor *cursor = tool == kToolSelect ? NSCursor.arrowCursor
                     : tool == kToolText   ? NSCursor.IBeamCursor
                                           : NSCursor.crosshairCursor;
    [self addCursorRect:self.visibleRect cursor:cursor];
}

- (void)mouseDown:(NSEvent *)event {
    if (g_state == NULL) return;
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];

    if (g_text_editor != nil) {
        if (NSPointInRect(p, g_text_editor.frame)) return;
        sm_text_edit_finish(YES);
    }

    const uint8_t tool = sm_current_tool();
    if (tool == kToolText) {
        sm_text_edit_begin(p, YES);
        return;
    }
    if (tool == kToolSelect && event.clickCount == 2 && sm_text_edit_begin(p, NO)) {
        return;
    }
    const SmModifiers modifiers = sm_modifiers_from_event(event);
    sm_on_mouse_down(g_state, p.x, p.y, &modifiers);
}

- (void)mouseDragged:(NSEvent *)event {
    if (g_state == NULL || g_text_editor != nil) return;
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    const SmModifiers modifiers = sm_modifiers_from_event(event);
    sm_on_mouse_drag(g_state, p.x, p.y, &modifiers);
}

- (void)mouseUp:(NSEvent *)event {
    if (g_state == NULL || g_text_editor != nil) return;
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    const SmModifiers modifiers = sm_modifiers_from_event(event);
    sm_on_mouse_up(g_state, p.x, p.y, &modifiers);
}

- (void)keyDown:(NSEvent *)event {
    if (g_state == NULL || g_text_editor != nil) {
        [super keyDown:event];
        return;
    }
    const SmModifiers modifiers = sm_modifiers_from_event(event);
    if (!sm_on_key_down(g_state, (uint16_t)event.keyCode, &modifiers)) {
        [super keyDown:event];
    }
}

- (void)copy:(id)sender {
    (void)sender;
    sm_text_edit_finish(YES);
    sm_copy_to_clipboard(g_state);
}

- (void)paste:(id)sender {
    (void)sender;
    sm_text_edit_finish(YES);
    sm_paste_from_clipboard(g_state);
}

- (void)undo:(id)sender {
    (void)sender;
    sm_undo(g_state);
}

- (void)redo:(id)sender {
    (void)sender;
    sm_redo(g_state);
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SmToolbarModel model = {0};
    sm_get_toolbar_model(g_state, &model);
    const SEL action = item.action;
    if (action == @selector(undo:)) return model.can_undo != 0;
    if (action == @selector(redo:)) return model.can_redo != 0;
    if (action == @selector(copy:)) return model.has_background != 0 || model.has_shapes != 0;
    return YES;
}

@end

// ---- App delegate ------------------------------------------------------------------

@interface SnapMarkAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation SnapMarkAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    g_state = sm_app_create();
    if (g_state == NULL) {
        [NSApp terminate:nil];
        return;
    }

    const NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
    g_window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 640)
                                           styleMask:style
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
    g_window.title = @"SnapMark";
    g_window.releasedWhenClosed = NO;
    g_window.delegate = self;
    g_window.contentMinSize = NSMakeSize(kMinContentWidth, kMinContentHeight);
    g_window.tabbingMode = NSWindowTabbingModeDisallowed;
    g_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *root = [[NSView alloc] initWithFrame:g_window.contentView.bounds];
    root.wantsLayer = YES;
    root.layer.backgroundColor = [NSColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0].CGColor;
    g_window.contentView = root;

    SnapMarkCanvasView *canvas = [[SnapMarkCanvasView alloc] initWithFrame:NSZeroRect];
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    g_canvas_view = canvas;
    [root addSubview:canvas];

    sm_build_toolbar(root, self);

    [NSLayoutConstraint activateConstraints:@[
        [canvas.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [canvas.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [canvas.topAnchor constraintEqualToAnchor:g_toolbar_view.bottomAnchor constant:kCanvasGap],
        [canvas.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    sm_refresh_toolbar(YES);

    // Open with whatever image is on the clipboard; this also sizes the window.
    if (!sm_paste_from_clipboard(g_state)) {
        [g_window center];
    }
    sm_show_window();

    // Not needed for the first frame, so set up after the window is on screen.
    dispatch_async(dispatch_get_main_queue(), ^{
        sm_build_main_menu();
        sm_setup_status_item(self);
        sm_setup_global_hotkey();
    });

    // Acceptance check used by scripts/selftest.sh: draw on the pasted
    // image, copy the result to the clipboard, and quit.
    if (getenv("SNAPMARK_SELFTEST") != NULL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [g_canvas_view displayIfNeeded];
            const NSRect b = g_canvas_view.bounds;
            const SmModifiers none = {0};
            const SmModifiers shift = {.shift = 1};
            const double x0 = NSMidX(b) - 100, y0 = NSMidY(b) - 60;
            // Every drawing tool (pen, ellipse, rect, arrow, line), plain and with
            // Shift, each with a long drag so the pen's point buffer has to grow.
            for (uint32_t tool = 2; tool <= 6; tool++) {
                for (int with_shift = 0; with_shift <= 1; with_shift++) {
                    const SmModifiers *mods = with_shift ? &shift : &none;
                    const double ox = (tool - 2) * 30.0, oy = with_shift * 30.0;
                    sm_set_tool(g_state, tool);
                    sm_on_mouse_down(g_state, x0 + ox, y0 + oy, mods);
                    for (int i = 1; i <= 200; i++) {
                        sm_on_mouse_drag(g_state, x0 + ox + i * 0.5, y0 + oy + i * 0.3, mods);
                    }
                    sm_on_mouse_up(g_state, x0 + ox + 100, y0 + oy + 60, mods);
                }
            }
            const char *label = "SnapMark self-test";
            sm_text_commit(g_state, 0, NSMidX(b) + 20, NSMidY(b) + 70, (const uint8_t *)label, strlen(label));
            const bool ok = sm_copy_to_clipboard(g_state);
            fprintf(stderr, "selftest_copy=%s\n", ok ? "ok" : "failed");
            [NSApp terminate:nil];
        });
    }

    const char *bench_seconds = getenv("SNAPMARK_BENCH_AUTOCLOSE");
    if (bench_seconds != NULL && atof(bench_seconds) > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(bench_seconds) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    }
}

- (void)statusItemClicked:(id)sender {
    (void)sender;
    sm_show_window_and_paste();
}

- (void)toolbarToolClicked:(NSButton *)sender {
    sm_text_edit_finish(YES);
    sm_set_tool(g_state, (uint32_t)sender.tag);
}

- (void)toolbarColorClicked:(NSButton *)sender {
    const NSInteger i = sender.tag;
    if (i < 0 || i >= 6) return;
    sm_set_color(g_state, kPresetColors[i][0], kPresetColors[i][1], kPresetColors[i][2], kPresetColors[i][3]);
    if (g_text_editor != nil) {
        g_text_editor.textColor = [NSColor colorWithSRGBRed:kPresetColors[i][0] green:kPresetColors[i][1]
                                                       blue:kPresetColors[i][2] alpha:kPresetColors[i][3]];
    }
}

- (void)toolbarStrokeClicked:(NSButton *)sender {
    const NSInteger i = sender.tag;
    if (i < 0 || i >= 3) return;
    sm_set_stroke_width(g_state, kStrokeWidths[i]);
}

- (void)toolbarCommandClicked:(NSButton *)sender {
    sm_text_edit_finish(YES);
    switch (sender.tag) {
        case 0: sm_undo(g_state); break;
        case 1: sm_redo(g_state); break;
        case 2: sm_paste_from_clipboard(g_state); break;
        case 3: sm_copy_to_clipboard(g_state); break;
        case 4: sm_clear_shapes(g_state); break;
        default: break;
    }
    [g_window makeFirstResponder:g_canvas_view];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    (void)flag;
    sm_show_window_and_paste();
    return NO;
}

// Coming back to SnapMark from another app (Cmd+Tab, clicking its window,
// Raycast/Spotlight) loads the newest clipboard image. Clipboard changes that
// are not images, and SnapMark's own Copy, leave the current document alone.
- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (g_state == NULL || !sm_platform_clipboard_changed()) return;
    sm_text_edit_finish(YES);
    sm_paste_from_clipboard(g_state);
    if (!g_window.isVisible) sm_show_window();
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    sm_platform_hide_window();
    return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    sm_text_edit_finish(YES);
    sm_teardown_global_hotkey();
    if (g_status_item != nil) {
        [[NSStatusBar systemStatusBar] removeStatusItem:g_status_item];
        g_status_item = nil;
    }
    if (g_state != NULL) {
        sm_app_destroy(g_state);
        g_state = NULL;
    }
}

@end

// ---- Pasteboard ------------------------------------------------------------------

// Redraws any image into 8-bit premultiplied RGBA, keeping its colour space
// when that is an RGB one (screenshots are usually Display P3).
static CGImageRef sm_normalize_image(CGImageRef source) {
    const size_t width = CGImageGetWidth(source);
    const size_t height = CGImageGetHeight(source);
    if (width == 0 || height == 0) return NULL;

    CGColorSpaceRef colorspace = CGImageGetColorSpace(source);
    CGColorSpaceRef owned = NULL;
    if (colorspace == NULL || CGColorSpaceGetModel(colorspace) != kCGColorSpaceModelRGB ||
        !CGColorSpaceSupportsOutput(colorspace)) {
        owned = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        colorspace = owned;
    }

    CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, 8, 0, colorspace,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (owned != NULL) CGColorSpaceRelease(owned);
    if (ctx == NULL) return NULL;

    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), source);
    CGImageRef result = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return result;
}

bool sm_platform_read_clipboard_image(CGImageRef *out_image, size_t *out_width, size_t *out_height,
                                      double *out_point_width, double *out_point_height) {
    if (out_image == NULL) return false;
    *out_image = NULL;

    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        g_seen_change_count = pasteboard.changeCount;

        // Prefer the raw PNG/TIFF data: it decodes at full pixel resolution
        // and carries the DPI that tells us the image's size in points.
        NSArray<NSImageRep *> *reps = nil;
        NSString *type = [pasteboard availableTypeFromArray:@[ NSPasteboardTypePNG, NSPasteboardTypeTIFF ]];
        if (type != nil) {
            NSData *data = [pasteboard dataForType:type];
            if (data != nil) reps = [NSBitmapImageRep imageRepsWithData:data];
        }
        NSImage *image = nil;
        if (reps.count == 0) {
            image = [[NSImage alloc] initWithPasteboard:pasteboard];
            reps = image.representations;
        }

        NSImageRep *best = nil;
        for (NSImageRep *rep in reps) {
            if (best == nil || rep.pixelsWide * rep.pixelsHigh > best.pixelsWide * best.pixelsHigh) best = rep;
        }

        CGImageRef cg = NULL;
        NSSize point_size = NSZeroSize;
        if ([best isKindOfClass:[NSBitmapImageRep class]]) {
            cg = ((NSBitmapImageRep *)best).CGImage;
            point_size = best.size;
        } else if (best != nil) {
            // Vector or other non-bitmap data: rasterize at 2x.
            point_size = best.size;
            NSRect rect = NSMakeRect(0, 0, point_size.width * 2.0, point_size.height * 2.0);
            cg = [best CGImageForProposedRect:&rect context:nil hints:nil];
        } else if (image != nil) {
            point_size = image.size;
            NSRect rect = NSMakeRect(0, 0, point_size.width, point_size.height);
            cg = [image CGImageForProposedRect:&rect context:nil hints:nil];
        }
        if (cg == NULL) return false;

        CGImageRef normalized = sm_normalize_image(cg);
        if (normalized == NULL) return false;

        const size_t width = CGImageGetWidth(normalized);
        const size_t height = CGImageGetHeight(normalized);
        if (point_size.width <= 0 || point_size.height <= 0) point_size = NSMakeSize(width, height);

        *out_image = normalized;
        if (out_width) *out_width = width;
        if (out_height) *out_height = height;
        if (out_point_width) *out_point_width = point_size.width;
        if (out_point_height) *out_point_height = point_size.height;
        return true;
    }
}

bool sm_platform_write_clipboard_rgba(const SmImageBuffer *image) {
    if (image == NULL || image->pixels == NULL || image->width == 0 || image->height == 0) return false;

    @autoreleasepool {
        CGColorSpaceRef owned = image->colorspace == NULL ? CGColorSpaceCreateWithName(kCGColorSpaceSRGB) : NULL;
        CGColorSpaceRef colorspace = image->colorspace != NULL ? image->colorspace : owned;

        CGContextRef ctx = CGBitmapContextCreate(image->pixels, image->width, image->height, 8, image->width * 4,
                                                 colorspace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        if (owned != NULL) CGColorSpaceRelease(owned);
        if (ctx == NULL) return false;
        CGImageRef cg = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (cg == NULL) return false;

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
        CGImageRelease(cg);
        if (rep == nil) return false;
        // Point size sets the PNG's DPI, so a Retina screenshot pastes back at
        // the same on-screen size it was taken at.
        if (image->point_width > 0 && image->point_height > 0) {
            rep.size = NSMakeSize(image->point_width, image->point_height);
        }

        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (png == nil) return false;

        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        const BOOL ok = [pasteboard setData:png forType:NSPasteboardTypePNG];
        g_seen_change_count = pasteboard.changeCount;
        if (ok) sm_flash_copied();
        return ok;
    }
}

bool sm_platform_clipboard_changed(void) {
    return [NSPasteboard generalPasteboard].changeCount != g_seen_change_count;
}

// ---- Text rendering ----------------------------------------------------------------
// Core Text directly: AppKit's NSString drawing pulls in the TextKit stack,
// which costs ~15 MB of resident memory at launch for one line of text.

static CTLineRef sm_create_line(const uint8_t *text, size_t text_len, double font_size) {
    CFStringRef string = CFStringCreateWithBytes(NULL, text, (CFIndex)text_len, kCFStringEncodingUTF8, false);
    if (string == NULL) return NULL;
    CTFontRef font = (__bridge CTFontRef)sm_annotation_font(font_size);
    const void *keys[] = {kCTFontAttributeName, kCTForegroundColorFromContextAttributeName};
    const void *values[] = {font, kCFBooleanTrue};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
    CTLineRef line = attributed != NULL ? CTLineCreateWithAttributedString(attributed) : NULL;
    if (attributed != NULL) CFRelease(attributed);
    CFRelease(attributes);
    CFRelease(string);
    return line;
}

void sm_platform_measure_text(const uint8_t *text, size_t text_len, double font_size, double *out_width,
                              double *out_height) {
    @autoreleasepool {
        CGFloat ascent = 0, descent = 0, leading = 0;
        double width = 0;
        CTLineRef line = text_len > 0 ? sm_create_line(text, text_len, font_size) : NULL;
        if (line != NULL) {
            width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
            CFRelease(line);
        } else {
            NSFont *font = sm_annotation_font(font_size);
            ascent = font.ascender;
            descent = -font.descender;
            leading = font.leading;
        }
        if (out_width) *out_width = ceil(width);
        if (out_height) *out_height = ceil(ascent + descent + leading);
    }
}

// Draws one line with its top-left at (x, y) in a flipped (y down) context.
void sm_platform_draw_text(CGContextRef ctx, double x, double y, const uint8_t *text, size_t text_len,
                           double font_size, float r, float g, float b, float a) {
    if (ctx == NULL || text_len == 0) return;
    @autoreleasepool {
        CTLineRef line = sm_create_line(text, text_len, font_size);
        if (line == NULL) return;
        CGFloat ascent = 0;
        CTLineGetTypographicBounds(line, &ascent, NULL, NULL);

        CGContextSaveGState(ctx);
        CGContextSetRGBFillColor(ctx, r, g, b, a);
        CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1.0, -1.0));
        CGContextSetTextPosition(ctx, x, y + ascent);
        CTLineDraw(line, ctx);
        CGContextRestoreGState(ctx);
        CFRelease(line);
    }
}

// ---- Entry -------------------------------------------------------------------------

void sm_platform_run_app(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        g_app_delegate = [SnapMarkAppDelegate new];
        app.delegate = g_app_delegate;
        [app run];
    }
}
