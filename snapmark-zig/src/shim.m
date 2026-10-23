#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

#import "bridge.h"

static SmAppState *g_state = NULL;
static NSWindow *g_window = nil;

static NSView *g_root_view = nil;
static NSView *g_toolbar_view = nil;
static NSView *g_canvas_view = nil;
static NSButton *g_tool_buttons[8] = {nil};
static NSButton *g_color_buttons[6] = {nil};
static NSButton *g_stroke_buttons[3] = {nil};
static NSButton *g_undo_button = nil;
static NSButton *g_redo_button = nil;
static NSButton *g_clear_button = nil;
static id g_app_delegate = nil;
static NSStatusItem *g_status_item = nil;
static NSTextField *g_text_editor = nil;
static id g_text_key_monitor = nil;
static id g_text_end_observer = nil;
static NSPoint g_text_origin = {0.0, 0.0};
static BOOL g_text_edit_closing = NO;
static EventHotKeyRef g_hotkey_ref = NULL;
static EventHandlerRef g_hotkey_handler_ref = NULL;

enum {
    kSnapMarkHotKeySignature = 'SMHK',
    kSnapMarkHotKeyId = 1,
};

static BOOL sm_text_tool_active(void);
static void sm_text_edit_begin(NSPoint point);
static void sm_text_edit_finish(BOOL commit);
static void sm_show_window_and_focus(void);
static void sm_show_window_and_paste(void);
static SmModifiers sm_shortcut_modifiers(BOOL with_shift);
static void sm_refresh_toolbar(void);
static void sm_build_toolbar(NSView *container, id target);
static void sm_setup_status_item(id target);
static void sm_setup_global_hotkey(void);
static void sm_teardown_global_hotkey(void);
static NSImage *sm_load_status_item_image(void);
static OSStatus sm_hotkey_handler(EventHandlerCallRef next_handler, EventRef event, void *user_data);

static const float kSnapMarkPresetColors[6][4] = {
    {1.00f, 0.20f, 0.20f, 1.00f}, // red
    {0.25f, 0.50f, 1.00f, 1.00f}, // blue
    {0.20f, 0.75f, 0.35f, 1.00f}, // green
    {1.00f, 0.78f, 0.20f, 1.00f}, // yellow
    {0.08f, 0.08f, 0.10f, 1.00f}, // black
    {1.00f, 1.00f, 1.00f, 1.00f}, // white
};

static const double kSnapMarkStrokeWidths[3] = {2.0, 4.0, 8.0};

static SmModifiers sm_modifiers_from_event(NSEvent *event) {
    const NSEventModifierFlags flags = event.modifierFlags;

    SmModifiers modifiers;
    modifiers.command = (flags & NSEventModifierFlagCommand) != 0;
    modifiers.shift = (flags & NSEventModifierFlagShift) != 0;
    modifiers.option = (flags & NSEventModifierFlagOption) != 0;
    modifiers.control = (flags & NSEventModifierFlagControl) != 0;
    return modifiers;
}

static SmModifiers sm_shortcut_modifiers(BOOL with_shift) {
    SmModifiers modifiers = {0};
    modifiers.command = 1;
    modifiers.shift = with_shift ? 1 : 0;
    return modifiers;
}

static BOOL sm_color_matches(const SmTextStyle *style, const float preset[4]) {
    if (style == NULL) return NO;
    const float eps = 0.02f;
    return fabsf(style->r - preset[0]) <= eps &&
           fabsf(style->g - preset[1]) <= eps &&
           fabsf(style->b - preset[2]) <= eps &&
           fabsf(style->a - preset[3]) <= eps;
}

static NSButton *sm_make_toolbar_button(NSString *title, NSInteger tag, id target, SEL action, BOOL toggle) {
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    button.tag = tag;
    button.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightSemibold];
    button.bezelStyle = NSBezelStyleRounded;
    button.buttonType = toggle ? NSButtonTypePushOnPushOff : NSButtonTypeMomentaryPushIn;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.focusRingType = NSFocusRingTypeNone;
    return button;
}

static NSView *sm_make_separator(void) {
    NSView *separator = [[NSView alloc] initWithFrame:NSZeroRect];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.wantsLayer = YES;
    separator.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.16].CGColor;
    [separator.widthAnchor constraintEqualToConstant:1.0].active = YES;
    [separator.heightAnchor constraintEqualToConstant:16.0].active = YES;
    return separator;
}

static void sm_refresh_toolbar(void) {
    if (g_state == NULL || g_toolbar_view == nil) return;

    SmToolbarModel model = {0};
    sm_get_toolbar_model(g_state, &model);
    SmTextStyle style = {0};
    sm_get_text_style(g_state, &style);

    for (uint8_t tool = 1; tool <= 7; tool++) {
        NSButton *button = g_tool_buttons[tool];
        if (button == nil) continue;
        button.state = (model.selected_tool == tool) ? NSControlStateValueOn : NSControlStateValueOff;
    }

    if (g_undo_button != nil) {
        g_undo_button.enabled = model.can_undo != 0;
    }
    if (g_redo_button != nil) {
        g_redo_button.enabled = model.can_redo != 0;
    }
    if (g_clear_button != nil) {
        g_clear_button.enabled = YES;
    }

    for (NSInteger i = 0; i < 6; i++) {
        NSButton *button = g_color_buttons[i];
        if (button == nil) continue;
        const BOOL selected = sm_color_matches(&style, kSnapMarkPresetColors[i]);

        button.wantsLayer = YES;
        button.layer.cornerRadius = 7.0;
        button.layer.backgroundColor = [NSColor colorWithRed:kSnapMarkPresetColors[i][0]
                                                       green:kSnapMarkPresetColors[i][1]
                                                        blue:kSnapMarkPresetColors[i][2]
                                                       alpha:kSnapMarkPresetColors[i][3]].CGColor;
        button.layer.borderWidth = selected ? 2.0 : 1.0;
        button.layer.borderColor = selected
            ? [NSColor colorWithRed:0.25 green:0.50 blue:1.0 alpha:1.0].CGColor
            : [NSColor colorWithWhite:0.95 alpha:0.28].CGColor;
        button.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    }

    for (NSInteger i = 0; i < 3; i++) {
        NSButton *button = g_stroke_buttons[i];
        if (button == nil) continue;
        const BOOL selected = fabs(style.stroke_width - kSnapMarkStrokeWidths[i]) < 0.11;
        button.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

static void sm_build_toolbar(NSView *container, id target) {
    if (container == nil) return;

    NSView *toolbar = [[NSView alloc] initWithFrame:NSZeroRect];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.wantsLayer = YES;
    toolbar.layer.backgroundColor = [NSColor colorWithRed:0.11 green:0.12 blue:0.15 alpha:0.94].CGColor;
    toolbar.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.12].CGColor;
    toolbar.layer.borderWidth = 1.0;
    toolbar.layer.cornerRadius = 10.0;
    [container addSubview:toolbar];
    g_toolbar_view = toolbar;

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.distribution = NSStackViewDistributionGravityAreas;
    stack.spacing = 5.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbar addSubview:stack];

    NSArray<NSString *> *tool_titles = @[
        @"S1",
        @"P2",
        @"C3",
        @"R4",
        @"A5",
        @"L6",
        @"T7",
    ];
    NSArray<NSString *> *tool_tips = @[
        @"Select (1)",
        @"Pen (2)",
        @"Circle (3)",
        @"Rect (4)",
        @"Arrow (5)",
        @"Line (6)",
        @"Text (7)",
    ];

    for (NSInteger idx = 0; idx < tool_titles.count; idx++) {
        NSInteger tool_id = idx + 1;
        NSButton *button = sm_make_toolbar_button(tool_titles[idx], tool_id, target, @selector(toolbarToolClicked:), YES);
        button.toolTip = tool_tips[idx];
        g_tool_buttons[tool_id] = button;
        [stack addArrangedSubview:button];
    }

    [stack addArrangedSubview:sm_make_separator()];

    NSArray<NSString *> *color_names = @[ @"Red", @"Blue", @"Green", @"Yellow", @"Black", @"White" ];
    for (NSInteger i = 0; i < color_names.count; i++) {
        NSButton *button = sm_make_toolbar_button(@"", i, target, @selector(toolbarColorClicked:), YES);
        button.bordered = NO;
        button.toolTip = color_names[i];
        [button.widthAnchor constraintEqualToConstant:14.0].active = YES;
        [button.heightAnchor constraintEqualToConstant:14.0].active = YES;
        g_color_buttons[i] = button;
        [stack addArrangedSubview:button];
    }

    [stack addArrangedSubview:sm_make_separator()];

    NSArray<NSString *> *stroke_titles = @[ @"2px", @"4px", @"8px" ];
    for (NSInteger i = 0; i < stroke_titles.count; i++) {
        NSButton *button = sm_make_toolbar_button(stroke_titles[i], i, target, @selector(toolbarStrokeClicked:), YES);
        button.toolTip = [NSString stringWithFormat:@"%@ stroke", stroke_titles[i]];
        g_stroke_buttons[i] = button;
        [stack addArrangedSubview:button];
    }

    [stack addArrangedSubview:sm_make_separator()];

    g_undo_button = sm_make_toolbar_button(@"⌘Z", 0, target, @selector(toolbarCommandClicked:), NO);
    g_undo_button.toolTip = @"Undo (Cmd/Ctrl+Z)";
    g_redo_button = sm_make_toolbar_button(@"⇧⌘Z", 1, target, @selector(toolbarCommandClicked:), NO);
    g_redo_button.toolTip = @"Redo (Cmd/Ctrl+Shift+Z)";
    NSButton *paste_button = sm_make_toolbar_button(@"⌘V", 2, target, @selector(toolbarCommandClicked:), NO);
    paste_button.toolTip = @"Paste (Cmd/Ctrl+V)";
    NSButton *copy_button = sm_make_toolbar_button(@"⌘C", 3, target, @selector(toolbarCommandClicked:), NO);
    copy_button.toolTip = @"Copy (Cmd/Ctrl+C)";
    g_clear_button = sm_make_toolbar_button(@"Clear", 4, target, @selector(toolbarCommandClicked:), NO);
    g_clear_button.toolTip = @"Clear Canvas";
    NSButton *hide_button = sm_make_toolbar_button(@"Esc", 5, target, @selector(toolbarCommandClicked:), NO);
    hide_button.toolTip = @"Hide Window (Esc)";

    [stack addArrangedSubview:g_undo_button];
    [stack addArrangedSubview:g_redo_button];
    [stack addArrangedSubview:paste_button];
    [stack addArrangedSubview:copy_button];
    [stack addArrangedSubview:g_clear_button];
    [stack addArrangedSubview:hide_button];

    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:container.topAnchor constant:8.0],
        [toolbar.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [toolbar.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:10.0],
        [toolbar.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-10.0],
        [toolbar.heightAnchor constraintEqualToConstant:40.0],

        [stack.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor constant:8.0],
        [stack.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor constant:-8.0],
        [stack.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [stack.heightAnchor constraintLessThanOrEqualToAnchor:toolbar.heightAnchor constant:-8.0],
    ]];
}

static void sm_show_window_and_focus(void) {
    if (g_window == nil) return;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [g_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (g_canvas_view != nil) {
        [g_window makeFirstResponder:g_canvas_view];
    }
}

static void sm_show_window_and_paste(void) {
    if (g_state == NULL) return;

    sm_show_window_and_focus();
    sm_paste_from_clipboard(g_state);
    sm_platform_invalidate();
}

static NSImage *sm_load_status_item_image(void) {
    NSArray<NSString *> *candidates = @[
        [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"icon_16x16.png"],
        [[[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"resources"] stringByAppendingPathComponent:@"icon_16x16.png"],
    ];

    for (NSString *path in candidates) {
        if (path.length == 0) continue;
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        if (image != nil) {
            image.template = YES;
            return image;
        }
    }

    if (@available(macOS 11.0, *)) {
        NSImage *symbol = [NSImage imageWithSystemSymbolName:@"scribble" accessibilityDescription:@"SnapMark"];
        if (symbol != nil) {
            symbol.template = YES;
            return symbol;
        }
    }

    return nil;
}

static void sm_setup_status_item(id target) {
    if (g_status_item != nil) return;

    g_status_item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    if (g_status_item == nil) return;

    NSStatusBarButton *button = g_status_item.button;
    if (button == nil) return;

    NSImage *icon = sm_load_status_item_image();
    if (icon != nil) {
        button.image = icon;
    } else {
        button.title = @"SM";
    }
    button.target = target;
    button.action = @selector(statusItemClicked:);
}

static OSStatus sm_hotkey_handler(EventHandlerCallRef next_handler, EventRef event, void *user_data) {
    (void)next_handler;
    (void)user_data;

    EventHotKeyID hotkey_id = {0};
    const OSStatus param_status = GetEventParameter(
        event,
        kEventParamDirectObject,
        typeEventHotKeyID,
        NULL,
        sizeof(hotkey_id),
        NULL,
        &hotkey_id
    );
    if (param_status != noErr) return param_status;

    if (hotkey_id.signature != kSnapMarkHotKeySignature || hotkey_id.id != kSnapMarkHotKeyId) {
        return eventNotHandledErr;
    }

    sm_show_window_and_paste();
    return noErr;
}

static void sm_setup_global_hotkey(void) {
    if (g_hotkey_ref != NULL) return;

    EventTypeSpec event_type = {
        .eventClass = kEventClassKeyboard,
        .eventKind = kEventHotKeyPressed,
    };

    const OSStatus handler_status = InstallApplicationEventHandler(
        sm_hotkey_handler,
        1,
        &event_type,
        NULL,
        &g_hotkey_handler_ref
    );
    if (handler_status != noErr) return;

    EventHotKeyID hotkey_id = {
        .signature = kSnapMarkHotKeySignature,
        .id = kSnapMarkHotKeyId,
    };

    const UInt32 modifiers = cmdKey | shiftKey;
    const OSStatus register_status = RegisterEventHotKey(
        kVK_ANSI_A,
        modifiers,
        hotkey_id,
        GetApplicationEventTarget(),
        0,
        &g_hotkey_ref
    );

    if (register_status != noErr) {
        if (g_hotkey_handler_ref != NULL) {
            RemoveEventHandler(g_hotkey_handler_ref);
            g_hotkey_handler_ref = NULL;
        }
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

static BOOL sm_text_tool_active(void) {
    if (g_state == NULL) return NO;

    SmToolbarModel model = {0};
    sm_get_toolbar_model(g_state, &model);
    return model.selected_tool == 7;
}

static void sm_text_edit_begin(NSPoint point) {
    if (g_state == NULL || g_canvas_view == nil) return;
    if (g_text_editor != nil) {
        sm_text_edit_finish(YES);
    }

    SmTextStyle style = {0};
    sm_get_text_style(g_state, &style);

    const CGFloat font_size = style.font_size > 0.0 ? style.font_size : 20.0;
    const CGFloat height = MAX(28.0, font_size * 1.6);
    const CGFloat width = 280.0;

    g_text_origin = point;
    g_text_editor = [[NSTextField alloc] initWithFrame:NSMakeRect(point.x, point.y, width, height)];
    g_text_editor.editable = YES;
    g_text_editor.selectable = YES;
    g_text_editor.bezeled = NO;
    g_text_editor.bordered = NO;
    g_text_editor.drawsBackground = NO;
    g_text_editor.focusRingType = NSFocusRingTypeNone;
    g_text_editor.font = [NSFont systemFontOfSize:font_size];
    g_text_editor.textColor = [NSColor colorWithRed:style.r green:style.g blue:style.b alpha:style.a > 0 ? style.a : 1.0];
    g_text_editor.stringValue = @"";
    g_text_editor.placeholderString = @"Type...";

    [g_canvas_view addSubview:g_text_editor];
    [g_canvas_view.window makeFirstResponder:g_text_editor];
    [g_text_editor selectText:nil];

    g_text_key_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (g_text_editor == nil) return event;

        if (event.keyCode == 53) {
            sm_text_edit_finish(NO);
            return nil;
        }

        if (event.keyCode == 36 || event.keyCode == 76) {
            sm_text_edit_finish(YES);
            return nil;
        }

        return event;
    }];

    g_text_end_observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSControlTextDidEndEditingNotification
                    object:g_text_editor
                     queue:nil
                usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        sm_text_edit_finish(YES);
    }];
}

static void sm_text_edit_finish(BOOL commit) {
    if (g_text_editor == nil || g_text_edit_closing) return;
    g_text_edit_closing = YES;

    NSString *value = g_text_editor.stringValue ?: @"";
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (commit && utf8.length > 0 && g_state != NULL) {
        sm_add_text(g_state, g_text_origin.x, g_text_origin.y, (const uint8_t *)utf8.bytes, (size_t)utf8.length);
    }

    if (g_text_end_observer != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:g_text_end_observer];
        g_text_end_observer = nil;
    }

    if (g_text_key_monitor != nil) {
        [NSEvent removeMonitor:g_text_key_monitor];
        g_text_key_monitor = nil;
    }

    [g_text_editor removeFromSuperview];
    g_text_editor = nil;

    if (g_canvas_view != nil && g_canvas_view.window != nil) {
        [g_canvas_view.window makeFirstResponder:g_canvas_view];
    }

    g_text_edit_closing = NO;
    sm_platform_invalidate();
}

@interface SnapMarkCanvasView : NSView
@end

@implementation SnapMarkCanvasView

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.window makeFirstResponder:self];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;

    if (g_state == NULL) {
        [[NSColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
        NSRectFill(self.bounds);
        return;
    }

    NSGraphicsContext *graphicsContext = [NSGraphicsContext currentContext];
    CGContextRef cg = graphicsContext.CGContext;
    const CGFloat scale = self.window.screen.backingScaleFactor > 0 ? self.window.screen.backingScaleFactor : 1.0;

    sm_draw(g_state, cg, self.bounds.size.width, self.bounds.size.height, scale);
}

- (void)mouseDown:(NSEvent *)event {
    if (g_state == NULL) return;

    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];

    if (g_text_editor != nil) {
        if (NSPointInRect(p, g_text_editor.frame)) {
            return;
        }
        sm_text_edit_finish(YES);
    }

    if (sm_text_tool_active()) {
        sm_text_edit_begin(p);
        return;
    }

    sm_on_mouse_down(g_state, p.x, p.y, sm_modifiers_from_event(event));
}

- (void)mouseDragged:(NSEvent *)event {
    if (g_state == NULL) return;

    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    sm_on_mouse_drag(g_state, p.x, p.y, sm_modifiers_from_event(event));
}

- (void)mouseUp:(NSEvent *)event {
    if (g_state == NULL) return;

    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    sm_on_mouse_up(g_state, p.x, p.y, sm_modifiers_from_event(event));
}

- (void)keyDown:(NSEvent *)event {
    if (g_text_editor != nil) {
        [super keyDown:event];
        return;
    }

    if (g_state == NULL) return;

    sm_on_key_down(g_state, (uint16_t)event.keyCode, sm_modifiers_from_event(event));
}

@end

@interface SnapMarkAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
- (void)statusItemClicked:(id)sender;
- (void)toolbarToolClicked:(id)sender;
- (void)toolbarColorClicked:(id)sender;
- (void)toolbarStrokeClicked:(id)sender;
- (void)toolbarCommandClicked:(id)sender;
@end

@implementation SnapMarkAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    g_state = sm_app_create();
    if (g_state == NULL) {
        [NSApp terminate:nil];
        return;
    }

    const NSRect frame = NSMakeRect(0, 0, 960, 640);
    const NSWindowStyleMask style = NSWindowStyleMaskTitled |
                                    NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskResizable |
                                    NSWindowStyleMaskMiniaturizable;

    g_window = [[NSWindow alloc] initWithContentRect:frame
                                           styleMask:style
                                             backing:NSBackingStoreBuffered
                                               defer:NO];

    g_window.title = @"SnapMark Zig";
    g_window.releasedWhenClosed = NO;
    g_window.delegate = self;
    g_window.minSize = NSMakeSize(760, 520);
    [g_window center];

    if (@available(macOS 10.14, *)) {
        g_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    }

    NSView *root = [[NSView alloc] initWithFrame:g_window.contentView.bounds];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.wantsLayer = YES;
    root.layer.backgroundColor = [NSColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0].CGColor;
    g_root_view = root;
    g_window.contentView = root;

    sm_build_toolbar(root, self);

    SnapMarkCanvasView *canvas = [[SnapMarkCanvasView alloc] initWithFrame:NSZeroRect];
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    g_canvas_view = canvas;
    [root addSubview:canvas];
    if (g_toolbar_view != nil) {
        [root addSubview:g_toolbar_view positioned:NSWindowAbove relativeTo:canvas];
    }

    [NSLayoutConstraint activateConstraints:@[
        [canvas.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [canvas.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [canvas.topAnchor constraintEqualToAnchor:root.topAnchor],
        [canvas.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    sm_setup_status_item(self);
    sm_setup_global_hotkey();
    sm_refresh_toolbar();
    sm_show_window_and_focus();

    const char *bench_seconds = getenv("SNAPMARK_BENCH_AUTOCLOSE");
    if (bench_seconds != NULL) {
        const double secs = atof(bench_seconds);
        if (secs > 0.0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [NSApp terminate:nil];
            });
        }
    }
}

- (void)statusItemClicked:(id)sender {
    (void)sender;
    sm_show_window_and_paste();
}

- (void)toolbarToolClicked:(id)sender {
    if (g_state == NULL) return;
    if (![sender isKindOfClass:[NSButton class]]) return;

    if (g_text_editor != nil) {
        sm_text_edit_finish(YES);
    }

    const NSInteger tool_id = ((NSButton *)sender).tag;
    if (tool_id >= 1 && tool_id <= 7) {
        sm_toolbar_click(g_state, (uint32_t)tool_id);
    }
}

- (void)toolbarColorClicked:(id)sender {
    if (g_state == NULL) return;
    if (![sender isKindOfClass:[NSButton class]]) return;

    const NSInteger index = ((NSButton *)sender).tag;
    if (index < 0 || index >= 6) return;

    const float *color = kSnapMarkPresetColors[index];
    sm_set_color(g_state, color[0], color[1], color[2], color[3]);
}

- (void)toolbarStrokeClicked:(id)sender {
    if (g_state == NULL) return;
    if (![sender isKindOfClass:[NSButton class]]) return;

    const NSInteger index = ((NSButton *)sender).tag;
    if (index < 0 || index >= 3) return;

    sm_set_stroke_width(g_state, kSnapMarkStrokeWidths[index]);
}

- (void)toolbarCommandClicked:(id)sender {
    if (g_state == NULL) return;
    if (![sender isKindOfClass:[NSButton class]]) return;

    if (g_text_editor != nil) {
        sm_text_edit_finish(YES);
    }

    const NSInteger action = ((NSButton *)sender).tag;
    switch (action) {
        case 0:
            sm_on_key_down(g_state, 6, sm_shortcut_modifiers(NO));
            break;
        case 1:
            sm_on_key_down(g_state, 6, sm_shortcut_modifiers(YES));
            break;
        case 2:
            sm_on_key_down(g_state, 9, sm_shortcut_modifiers(NO));
            break;
        case 3:
            sm_on_key_down(g_state, 8, sm_shortcut_modifiers(NO));
            break;
        case 4:
            sm_clear_document(g_state);
            break;
        case 5:
            sm_platform_hide_window();
            break;
        default:
            break;
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    (void)flag;
    sm_show_window_and_focus();
    return YES;
}

- (BOOL)windowShouldClose:(id)sender {
    (void)sender;

    sm_text_edit_finish(YES);
    [g_window orderOut:nil];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
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

bool sm_platform_read_clipboard_rgba(SmImageBuffer *out_image) {
    if (out_image == NULL) return false;

    out_image->pixels = NULL;
    out_image->width = 0;
    out_image->height = 0;

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSImage *image = [[NSImage alloc] initWithPasteboard:pasteboard];
    if (image == nil) return false;

    NSRect proposed = NSMakeRect(0, 0, image.size.width, image.size.height);
    CGImageRef cg = [image CGImageForProposedRect:&proposed context:nil hints:nil];
    if (cg == nil) return false;

    const size_t width = CGImageGetWidth(cg);
    const size_t height = CGImageGetHeight(cg);
    if (width == 0 || height == 0) return false;

    const size_t bytes_per_row = width * 4;
    const size_t len = bytes_per_row * height;

    uint8_t *pixels = malloc(len);
    if (pixels == NULL) return false;

    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    if (colorspace == NULL) {
        free(pixels);
        return false;
    }

    CGContextRef ctx = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        bytes_per_row,
        colorspace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorspace);

    if (ctx == NULL) {
        free(pixels);
        return false;
    }

    CGContextTranslateCTM(ctx, 0, (CGFloat)height);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cg);
    CGContextRelease(ctx);

    out_image->pixels = pixels;
    out_image->width = width;
    out_image->height = height;
    return true;
}

bool sm_platform_write_clipboard_rgba(const SmImageBuffer *image) {
    if (image == NULL || image->pixels == NULL || image->width == 0 || image->height == 0) {
        return false;
    }

    const size_t bytes_per_row = image->width * 4;

    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    if (colorspace == NULL) return false;

    CGContextRef ctx = CGBitmapContextCreate(
        (void *)image->pixels,
        image->width,
        image->height,
        8,
        bytes_per_row,
        colorspace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorspace);

    if (ctx == NULL) return false;

    CGImageRef cg_image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    if (cg_image == NULL) return false;

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg_image];
    CGImageRelease(cg_image);
    if (rep == nil) return false;

    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (png == nil) return false;

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    return [pasteboard setData:png forType:NSPasteboardTypePNG] == YES;
}

void sm_platform_free(void *ptr) {
    free(ptr);
}

void sm_platform_invalidate(void) {
    if (g_canvas_view == nil) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        sm_refresh_toolbar();
        [g_canvas_view setNeedsDisplay:YES];
    });
}

void sm_platform_hide_window(void) {
    if (g_window == nil) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        sm_text_edit_finish(YES);
        [g_window orderOut:nil];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    });
}

void sm_platform_run_app(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        g_app_delegate = [SnapMarkAppDelegate new];
        app.delegate = g_app_delegate;
        [app run];
    }
}
