const std = @import("std");
const c = @import("c.zig").c;
const engine = @import("engine");
const extra = @import("extra.zig");
const print3 = @import("print3.zig");

const Fn = ?*const anyopaque;

pub const Base = extern struct {
    parent: c.GtkContainer,
    priv: ?*anyopaque,
};

pub const ContainerClass = extern struct {
    parent: c.GtkWidgetClass,
    add: Fn,
    remove: Fn,
    check_resize: Fn,
    forall: ?*const fn ([*c]c.GtkContainer, c.gboolean, c.GtkCallback, c.gpointer) callconv(.c) void,
    set_focus_child: Fn,
    child_type: Fn,
    composite_name: Fn,
    set_child_property: Fn,
    get_child_property: Fn,
    get_path_for_child: Fn,
    flags: c_uint,
    reserved: [8]Fn,
};

pub const BaseClass = extern struct {
    parent: ContainerClass,
    reserved: [4]Fn,
};

pub const View = extern struct {
    parent: Base,
    priv: *Priv,
};

pub const ViewClass = extern struct {
    parent: BaseClass,
    load_changed: Fn,
    load_failed: Fn,
    create: Fn,
    ready_to_show: Fn,
    run_as_modal: Fn,
    close: Fn,
    script_dialog: Fn,
    decide_policy: Fn,
    permission_request: Fn,
    mouse_target_changed: Fn,
    print: Fn,
    resource_load_started: Fn,
    enter_fullscreen: Fn,
    leave_fullscreen: Fn,
    run_file_chooser: Fn,
    context_menu: Fn,
    context_menu_dismissed: Fn,
    submit_form: Fn,
    insecure_content_detected: Fn,
    web_process_crashed: Fn,
    authenticate: Fn,
    load_failed_with_tls_errors: Fn,
    show_notification: Fn,
    run_color_chooser: Fn,
    show_option_menu: Fn,
    web_process_terminated: Fn,
    user_message_received: Fn,
    query_permission_state: Fn,
};

const MAX_CONSTRUCT = 16;

pub const Priv = extern struct {
    web: ?*c.GObject,
    view: ?*c.WPEView,
    toplevel: ?*c.WPEToplevel,
    surface: ?*c.cairo_surface_t,
    favicon: ?*c.cairo_surface_t,
    clock: ?*c.GdkFrameClock,
    paint: c.gulong,
    fresh: c.gboolean,
    n: c.guint,
    names: [MAX_CONSTRUCT][*c]const u8,
    values: [MAX_CONSTRUCT]c.GValue,
};

const Signal = struct { name: [:0]const u8, field: []const u8 };

const signals = [_]Signal{
    .{ .name = "load-changed", .field = "load_changed" },
    .{ .name = "load-failed", .field = "load_failed" },
    .{ .name = "load-failed-with-tls-errors", .field = "load_failed_with_tls_errors" },
    .{ .name = "create", .field = "create" },
    .{ .name = "ready-to-show", .field = "ready_to_show" },
    .{ .name = "run-as-modal", .field = "run_as_modal" },
    .{ .name = "close", .field = "close" },
    .{ .name = "script-dialog", .field = "script_dialog" },
    .{ .name = "decide-policy", .field = "decide_policy" },
    .{ .name = "permission-request", .field = "permission_request" },
    .{ .name = "mouse-target-changed", .field = "mouse_target_changed" },
    .{ .name = "resource-load-started", .field = "resource_load_started" },
    .{ .name = "enter-fullscreen", .field = "enter_fullscreen" },
    .{ .name = "leave-fullscreen", .field = "leave_fullscreen" },
    .{ .name = "run-file-chooser", .field = "run_file_chooser" },
    .{ .name = "context-menu-dismissed", .field = "context_menu_dismissed" },
    .{ .name = "submit-form", .field = "submit_form" },
    .{ .name = "insecure-content-detected", .field = "insecure_content_detected" },
    .{ .name = "web-process-terminated", .field = "web_process_terminated" },
    .{ .name = "authenticate", .field = "authenticate" },
    .{ .name = "show-notification", .field = "show_notification" },
    .{ .name = "user-message-received", .field = "user_message_received" },
    .{ .name = "query-permission-state", .field = "query_permission_state" },
    .{ .name = "context-menu", .field = "context_menu" },
    .{ .name = "show-option-menu", .field = "show_option_menu" },
    .{ .name = "web-process-crashed", .field = "web_process_crashed" },
    .{ .name = "print", .field = "print" },
    .{ .name = "run-color-chooser", .field = "run_color_chooser" },
};

const CREATE = 3;
const TERMINATED = 18;
const CONTEXT_MENU = 23;
const OPTION_MENU = 24;
const CRASHED = 25;
const PRINT = 26;
const COLOR_CHOOSER = 27;
const RELAYED = CONTEXT_MENU;

const props = [_][:0]const u8{
    "web-context",                 "related-view",                 "settings",
    "user-content-manager",        "title",                        "estimated-load-progress",
    "favicon",                     "uri",                          "zoom-level",
    "is-loading",                  "is-playing-audio",             "is-ephemeral",
    "is-controlled-by-automation", "automation-presentation-type", "editable",
    "page-id",                     "is-muted",                     "website-policies",
    "is-web-process-responsive",   "camera-capture-state",         "microphone-capture-state",
    "display-capture-state",       "web-extension-mode",           "default-content-security-policy",
    "theme-color",                 "is-immersive-mode-enabled",
};

var base_type: c.GType = 0;
var view_type: c.GType = 0;
var base_parent: ?*c.GtkWidgetClass = null;
var parent_class: ?*c.GObjectClass = null;
var signal_ids = [_]c.guint{0} ** signals.len;
var engine_ids = [_]c.guint{0} ** signals.len;
var proxy_quark: c.GQuark = 0;
var shared: ?*c.WPEDisplay = null;

fn of(p: anytype) *View {
    return @ptrCast(@alignCast(p));
}

fn isA(o: ?*anyopaque, t: c.GType) bool {
    const p = o orelse return false;
    return c.g_type_check_instance_is_a(@ptrCast(@alignCast(p)), t) != 0;
}

pub fn engineFn(comptime name: [:0]const u8) *const @TypeOf(@field(c, name)) {
    return engine.lookup(name, @TypeOf(@field(c, name)));
}

pub fn display() ?*c.WPEDisplay {
    if (shared) |d| return d;
    const d = c.fotone_display_new(null);
    var err: [*c]c.GError = null;
    if (c.wpe_display_connect(d, &err) == 0) {
        std.log.warn("fotone display: {s}", .{if (err) |e| std.mem.span(e.*.message) else "unknown error"});
        c.g_clear_error(&err);
    }
    shared = d;
    return d;
}

pub fn baseType() c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(&base_type)) != 0) {
        const t = c.g_type_register_static_simple(c.gtk_container_get_type(), c.g_intern_static_string("WebKitWebViewBase"), @sizeOf(BaseClass), baseClassInit, @sizeOf(Base), null, 0);
        c.g_once_init_leave_pointer(@ptrCast(&base_type), @ptrFromInt(t));
    }
    return base_type;
}

pub fn viewType() c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(&view_type)) != 0) {
        const t = c.g_type_register_static_simple(baseType(), c.g_intern_static_string("WebKitWebView"), @sizeOf(ViewClass), classInit, @sizeOf(View), instanceInit, 0);
        c.g_once_init_leave_pointer(@ptrCast(&view_type), @ptrFromInt(t));
    }
    return view_type;
}

pub fn toEngine(p: ?*anyopaque) ?*anyopaque {
    if (!isA(p, viewType())) return p;
    return of(p).priv.web;
}

pub fn toProxy(p: ?*anyopaque) ?*anyopaque {
    const o = p orelse return null;
    if (isA(o, viewType())) return o;
    return c.g_object_get_qdata(@ptrCast(@alignCast(o)), proxy_quark) orelse o;
}

fn releaseBytes(data: ?*anyopaque) callconv(.c) void {
    c.g_bytes_unref(@ptrCast(data));
}

const surface_key: c.cairo_user_data_key_t = .{ .unused = 0 };

pub fn bufferSurface(buffer: *c.WPEBuffer) ?*c.cairo_surface_t {
    const w: c_int = c.wpe_buffer_get_width(buffer);
    const h: c_int = c.wpe_buffer_get_height(buffer);
    var bytes: ?*c.GBytes = null;
    var stride: c_int = 0;
    if (isA(buffer, c.wpe_buffer_shm_get_type()) and c.wpe_buffer_shm_get_format(@ptrCast(buffer)) == c.WPE_PIXEL_FORMAT_ARGB8888) {
        bytes = c.g_bytes_ref(c.wpe_buffer_shm_get_data(@ptrCast(buffer)));
        stride = @intCast(c.wpe_buffer_shm_get_stride(@ptrCast(buffer)));
    } else {
        bytes = c.wpe_buffer_import_to_pixels(buffer, null);
        stride = w * 4;
    }
    const b = bytes orelse return null;
    var size: usize = 0;
    const data = c.g_bytes_get_data(b, &size);
    if (size < @as(usize, @intCast(stride)) * @as(usize, @intCast(h))) {
        c.g_bytes_unref(b);
        return null;
    }
    const s = c.cairo_image_surface_create_for_data(@ptrCast(@constCast(data)), c.CAIRO_FORMAT_ARGB32, w, h, stride);
    _ = c.cairo_surface_set_user_data(s, &surface_key, b, releaseBytes);
    return s;
}

fn frame(view: ?*c.WPEView, buffer: ?*c.WPEBuffer, data: c.gpointer) callconv(.c) void {
    const v = of(data);
    const s = bufferSurface(buffer orelse return) orelse return c.fotone_view_frame_presented(view);
    if (v.priv.surface) |old| c.cairo_surface_destroy(old);
    v.priv.surface = s;
    v.priv.fresh = 1;
    c.gtk_widget_queue_draw(@ptrCast(v));
}

fn afterPaint(_: ?*c.GdkFrameClock, data: c.gpointer) callconv(.c) void {
    const v = of(data);
    if (v.priv.fresh == 0) return;
    v.priv.fresh = 0;
    if (v.priv.view) |w| c.fotone_view_frame_presented(w);
}

fn draw(wd: [*c]c.GtkWidget, cr: ?*c.cairo_t) callconv(.c) c.gboolean {
    const v = of(wd);
    const s = v.priv.surface orelse return 0;
    const scale: f64 = @floatFromInt(@max(c.gtk_widget_get_scale_factor(wd), 1));
    c.cairo_save(cr);
    c.cairo_scale(cr, 1 / scale, 1 / scale);
    c.cairo_set_source_surface(cr, s, 0, 0);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    c.cairo_paint(cr);
    c.cairo_restore(cr);
    return 0;
}

fn realize(wd: [*c]c.GtkWidget) callconv(.c) void {
    var a: c.GtkAllocation = undefined;
    c.gtk_widget_get_allocation(wd, &a);
    var attr = std.mem.zeroes(c.GdkWindowAttr);
    attr.window_type = c.GDK_WINDOW_CHILD;
    attr.x = a.x;
    attr.y = a.y;
    attr.width = a.width;
    attr.height = a.height;
    attr.wclass = c.GDK_INPUT_OUTPUT;
    attr.visual = c.gtk_widget_get_visual(wd);
    attr.event_mask = c.gtk_widget_get_events(wd) | c.GDK_EXPOSURE_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_BUTTON_PRESS_MASK |
        c.GDK_BUTTON_RELEASE_MASK | c.GDK_SCROLL_MASK | c.GDK_SMOOTH_SCROLL_MASK | c.GDK_KEY_PRESS_MASK | c.GDK_KEY_RELEASE_MASK |
        c.GDK_ENTER_NOTIFY_MASK | c.GDK_LEAVE_NOTIFY_MASK | c.GDK_FOCUS_CHANGE_MASK | c.GDK_TOUCH_MASK;
    const win = c.gdk_window_new(c.gtk_widget_get_parent_window(wd), &attr, c.GDK_WA_X | c.GDK_WA_Y | c.GDK_WA_VISUAL);
    c.gtk_widget_set_window(wd, win);
    c.gtk_widget_register_window(wd, win);
    c.gtk_widget_set_realized(wd, 1);
}

fn sizeAllocate(wd: [*c]c.GtkWidget, a: [*c]c.GtkAllocation) callconv(.c) void {
    c.gtk_widget_set_allocation(wd, a);
    if (c.gtk_widget_get_realized(wd) != 0) c.gdk_window_move_resize(c.gtk_widget_get_window(wd), a.*.x, a.*.y, a.*.width, a.*.height);
    const v = of(wd);
    if (v.priv.toplevel) |t| c.fotone_toplevel_configure(t, a.*.width, a.*.height, @floatFromInt(@max(c.gtk_widget_get_scale_factor(wd), 1)));
}

fn map(wd: [*c]c.GtkWidget) callconv(.c) void {
    base_parent.?.map.?(wd);
    const v = of(wd);
    v.priv.clock = c.gtk_widget_get_frame_clock(wd);
    if (v.priv.clock) |k| v.priv.paint = c.g_signal_connect_data(k, "after-paint", @ptrCast(&afterPaint), v, null, 0);
    if (v.priv.view) |w| c.wpe_view_set_toplevel(w, v.priv.toplevel);
}

fn unmap(wd: [*c]c.GtkWidget) callconv(.c) void {
    const v = of(wd);
    if (v.priv.view) |w| c.wpe_view_set_toplevel(w, null);
    if (v.priv.clock) |k| c.g_signal_handler_disconnect(k, v.priv.paint);
    v.priv.clock = null;
    v.priv.paint = 0;
    base_parent.?.unmap.?(wd);
}

const modifier_pairs = [_][2]c_uint{
        .{ c.GDK_CONTROL_MASK, c.WPE_MODIFIER_KEYBOARD_CONTROL },
        .{ c.GDK_SHIFT_MASK, c.WPE_MODIFIER_KEYBOARD_SHIFT },
        .{ c.GDK_MOD1_MASK, c.WPE_MODIFIER_KEYBOARD_ALT },
        .{ c.GDK_META_MASK | c.GDK_SUPER_MASK, c.WPE_MODIFIER_KEYBOARD_META },
        .{ c.GDK_LOCK_MASK, c.WPE_MODIFIER_KEYBOARD_CAPS_LOCK },
        .{ c.GDK_BUTTON1_MASK, c.WPE_MODIFIER_POINTER_BUTTON1 },
        .{ c.GDK_BUTTON2_MASK, c.WPE_MODIFIER_POINTER_BUTTON2 },
        .{ c.GDK_BUTTON3_MASK, c.WPE_MODIFIER_POINTER_BUTTON3 },
        .{ c.GDK_BUTTON4_MASK, c.WPE_MODIFIER_POINTER_BUTTON4 },
        .{ c.GDK_BUTTON5_MASK, c.WPE_MODIFIER_POINTER_BUTTON5 },
};

pub fn modifiers(state: c.GdkModifierType) c.WPEModifiers {
    var m: c_uint = 0;
    for (modifier_pairs) |p| {
        if (state & p[0] != 0) m |= p[1];
    }
    return m;
}

pub fn gdkModifiers(state: c.WPEModifiers) c.GdkModifierType {
    var m: c_uint = 0;
    for (modifier_pairs) |p| {
        if (state & p[1] != 0) m |= p[0] & ~@as(c_uint, c.GDK_SUPER_MASK);
    }
    return m;
}

fn source(ev: ?*c.GdkEvent) c.WPEInputSource {
    const dev = c.gdk_event_get_source_device(ev) orelse return c.WPE_INPUT_SOURCE_MOUSE;
    return switch (c.gdk_device_get_source(dev)) {
        c.GDK_SOURCE_TOUCHPAD => c.WPE_INPUT_SOURCE_TOUCHPAD,
        c.GDK_SOURCE_TOUCHSCREEN => c.WPE_INPUT_SOURCE_TOUCHSCREEN,
        c.GDK_SOURCE_PEN => c.WPE_INPUT_SOURCE_PEN,
        c.GDK_SOURCE_KEYBOARD => c.WPE_INPUT_SOURCE_KEYBOARD,
        c.GDK_SOURCE_TRACKPOINT => c.WPE_INPUT_SOURCE_TRACKPOINT,
        else => c.WPE_INPUT_SOURCE_MOUSE,
    };
}

fn translate(v: *View, ev: ?*c.GdkEvent) ?*c.WPEEvent {
    const w = v.priv.view orelse return null;
    const time = c.gdk_event_get_time(ev);
    var state: c.GdkModifierType = 0;
    _ = c.gdk_event_get_state(ev, &state);
    const mods = modifiers(state);
    const src = source(ev);
    var x: f64 = 0;
    var y: f64 = 0;
    _ = c.gdk_event_get_coords(ev, &x, &y);
    const kind = c.gdk_event_get_event_type(ev);
    switch (kind) {
        c.GDK_MOTION_NOTIFY, c.GDK_ENTER_NOTIFY, c.GDK_LEAVE_NOTIFY => {
            const t: c.WPEEventType = switch (kind) {
                c.GDK_ENTER_NOTIFY => c.WPE_EVENT_POINTER_ENTER,
                c.GDK_LEAVE_NOTIFY => c.WPE_EVENT_POINTER_LEAVE,
                else => c.WPE_EVENT_POINTER_MOVE,
            };
            return c.wpe_event_pointer_move_new(t, w, src, time, mods, x, y, 0, 0);
        },
        c.GDK_BUTTON_PRESS, c.GDK_BUTTON_RELEASE => {
            const down = kind == c.GDK_BUTTON_PRESS;
            if (down) c.gtk_widget_grab_focus(@ptrCast(v));
            var button: c.guint = 0;
            _ = c.gdk_event_get_button(ev, &button);
            const t: c.WPEEventType = if (down) c.WPE_EVENT_POINTER_DOWN else c.WPE_EVENT_POINTER_UP;
            const count = if (down) c.wpe_view_compute_press_count(w, x, y, button, time) else 0;
            return c.wpe_event_pointer_button_new(t, w, src, time, mods, button, x, y, count);
        },
        c.GDK_SCROLL => {
            var dx: f64 = 0;
            var dy: f64 = 0;
            var dir: c.GdkScrollDirection = undefined;
            var precise = false;
            if (c.gdk_event_get_scroll_direction(ev, &dir) != 0) switch (dir) {
                c.GDK_SCROLL_UP => dy = -1,
                c.GDK_SCROLL_DOWN => dy = 1,
                c.GDK_SCROLL_LEFT => dx = -1,
                c.GDK_SCROLL_RIGHT => dx = 1,
                else => {},
            } else if (c.gdk_event_get_scroll_deltas(ev, &dx, &dy) != 0) precise = src == c.WPE_INPUT_SOURCE_TOUCHPAD;
            const stop = c.gdk_event_is_scroll_stop_event(ev) != 0;
            return c.wpe_event_scroll_new(w, src, time, mods, -dx, -dy, @intFromBool(precise), @intFromBool(stop), x, y);
        },
        c.GDK_KEY_PRESS, c.GDK_KEY_RELEASE => {
            const t: c.WPEEventType = if (kind == c.GDK_KEY_PRESS) c.WPE_EVENT_KEYBOARD_KEY_DOWN else c.WPE_EVENT_KEYBOARD_KEY_UP;
            var keyval: c.guint = 0;
            var keycode: c.guint16 = 0;
            _ = c.gdk_event_get_keyval(ev, &keyval);
            _ = c.gdk_event_get_keycode(ev, &keycode);
            return c.wpe_event_keyboard_new(t, w, c.WPE_INPUT_SOURCE_KEYBOARD, time, mods, keycode, keyval);
        },
        c.GDK_TOUCH_BEGIN, c.GDK_TOUCH_UPDATE, c.GDK_TOUCH_END, c.GDK_TOUCH_CANCEL => {
            const t: c.WPEEventType = switch (kind) {
                c.GDK_TOUCH_BEGIN => c.WPE_EVENT_TOUCH_DOWN,
                c.GDK_TOUCH_UPDATE => c.WPE_EVENT_TOUCH_MOVE,
                c.GDK_TOUCH_END => c.WPE_EVENT_TOUCH_UP,
                else => c.WPE_EVENT_TOUCH_CANCEL,
            };
            const seq: u32 = @truncate(@intFromPtr(c.gdk_event_get_event_sequence(ev)));
            return c.wpe_event_touch_new(t, w, src, time, mods, seq, x, y);
        },
        else => return null,
    }
}

fn onEvent(wd: [*c]c.GtkWidget, ev: ?*c.GdkEvent) callconv(.c) c.gboolean {
    const e = translate(of(wd), ev) orelse return 0;
    defer c.wpe_event_unref(e);
    c.wpe_view_event(of(wd).priv.view, e);
    return 1;
}

fn focusIn(wd: [*c]c.GtkWidget, _: [*c]c.GdkEventFocus) callconv(.c) c.gboolean {
    if (of(wd).priv.view) |w| c.wpe_view_focus_in(w);
    return 0;
}

fn focusOut(wd: [*c]c.GtkWidget, _: [*c]c.GdkEventFocus) callconv(.c) c.gboolean {
    if (of(wd).priv.view) |w| c.wpe_view_focus_out(w);
    return 0;
}

fn forall(_: [*c]c.GtkContainer, _: c.gboolean, _: c.GtkCallback, _: c.gpointer) callconv(.c) void {}

fn baseClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    base_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
    wc.realize = realize;
    wc.size_allocate = sizeAllocate;
    wc.draw = draw;
    wc.map = map;
    wc.unmap = unmap;
    wc.button_press_event = @ptrCast(&onEvent);
    wc.button_release_event = @ptrCast(&onEvent);
    wc.motion_notify_event = @ptrCast(&onEvent);
    wc.scroll_event = @ptrCast(&onEvent);
    wc.key_press_event = @ptrCast(&onEvent);
    wc.key_release_event = @ptrCast(&onEvent);
    wc.enter_notify_event = @ptrCast(&onEvent);
    wc.leave_notify_event = @ptrCast(&onEvent);
    wc.touch_event = @ptrCast(&onEvent);
    wc.focus_in_event = focusIn;
    wc.focus_out_event = focusOut;
    const cc: *ContainerClass = @ptrCast(@alignCast(klass));
    cc.forall = forall;
    c.gtk_widget_class_set_css_name(wc, "webkitwebview");
}

fn instanceInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const v = of(inst);
    v.priv = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Priv))));
    v.parent.priv = null;
    const wd: *c.GtkWidget = @ptrCast(v);
    c.gtk_widget_set_has_window(wd, 1);
    c.gtk_widget_set_can_focus(wd, 1);
    c.gtk_widget_set_hexpand(wd, 1);
    c.gtk_widget_set_vexpand(wd, 1);
}

fn mapType(t: c.GType) c.GType {
    const flag = t & c.G_SIGNAL_TYPE_STATIC_SCOPE;
    const bare = t & ~@as(c.GType, c.G_SIGNAL_TYPE_STATIC_SCOPE);
    if (bare == c.webkit_rectangle_get_type()) return c.gdk_rectangle_get_type() | flag;
    if (bare == engine.viewType()) return viewType() | flag;
    return t;
}

fn objectHandled(_: ?*c.GSignalInvocationHint, ret: [*c]c.GValue, handler: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    const o = c.g_value_get_object(handler);
    c.g_value_set_object(ret, o);
    return @intFromBool(o == null);
}

fn installSignals(itype: c.GType) void {
    const etype = engine.viewType();
    const last = c.G_SIGNAL_RUN_LAST;
    inline for (signals, 0..) |s, i| {
        const offset = @offsetOf(ViewClass, s.field);
        const closure = c.g_signal_type_cclosure_new(itype, offset);
        const handled = c.g_signal_accumulator_true_handled;
        const generic = c.g_cclosure_marshal_generic;
        switch (i) {
            CONTEXT_MENU => {
                var types = [_]c.GType{ c.webkit_context_menu_get_type(), c.gdk_event_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE, c.webkit_hit_test_result_get_type() };
                signal_ids[i] = c.g_signal_newv(s.name, itype, last, closure, handled, null, generic, c.G_TYPE_BOOLEAN, types.len, &types);
            },
            OPTION_MENU => {
                var types = [_]c.GType{ c.webkit_option_menu_get_type(), c.gdk_event_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE, c.gdk_rectangle_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE };
                signal_ids[i] = c.g_signal_newv(s.name, itype, last, closure, handled, null, generic, c.G_TYPE_BOOLEAN, types.len, &types);
            },
            CRASHED => signal_ids[i] = c.g_signal_newv(s.name, itype, last, closure, handled, null, generic, c.G_TYPE_BOOLEAN, 0, null),
            PRINT, COLOR_CHOOSER => {
                var types = [_]c.GType{if (i == PRINT) extra.printOperationType() else extra.colorChooserRequestType()};
                signal_ids[i] = c.g_signal_newv(s.name, itype, last, closure, handled, null, generic, c.G_TYPE_BOOLEAN, types.len, &types);
            },
            else => {
                var q: c.GSignalQuery = undefined;
                c.g_signal_query(c.g_signal_lookup(s.name, etype), &q);
                if (q.signal_id != 0) {
                    var types: [8]c.GType = undefined;
                    var k: usize = 0;
                    while (k < q.n_params) : (k += 1) types[k] = mapType(q.param_types[k]);
                    const ret = if (i == CREATE) c.gtk_widget_get_type() else mapType(q.return_type);
                    const acc: c.GSignalAccumulator = if (i == CREATE) objectHandled else if (q.return_type == c.G_TYPE_BOOLEAN) handled else null;
                    signal_ids[i] = c.g_signal_newv(s.name, itype, q.signal_flags, closure, acc, null, generic, ret, q.n_params, &types);
                }
            },
        }
    }
}

fn copySpec(name: [:0]const u8, p: *c.GParamSpec) ?*c.GParamSpec {
    const flags = p.flags;
    var vt = p.value_type;
    if (vt == engine.viewType()) vt = viewType();
    const kind = std.mem.span(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(p)).g_class.*.g_type));
    if (std.mem.eql(u8, kind, "GParamObject")) return c.g_param_spec_object(name, null, null, vt, flags);
    if (std.mem.eql(u8, kind, "GParamBoxed")) return c.g_param_spec_boxed(name, null, null, vt, flags);
    const def = c.g_param_spec_get_default_value(p);
    if (std.mem.eql(u8, kind, "GParamString")) return c.g_param_spec_string(name, null, null, c.g_value_get_string(def), flags);
    if (std.mem.eql(u8, kind, "GParamBoolean")) return c.g_param_spec_boolean(name, null, null, c.g_value_get_boolean(def), flags);
    if (std.mem.eql(u8, kind, "GParamEnum")) return c.g_param_spec_enum(name, null, null, vt, c.g_value_get_enum(def), flags);
    if (std.mem.eql(u8, kind, "GParamDouble")) {
        const d: *c.GParamSpecDouble = @ptrCast(p);
        return c.g_param_spec_double(name, null, null, d.minimum, d.maximum, d.default_value, flags);
    }
    if (std.mem.eql(u8, kind, "GParamUInt64")) {
        const d: *c.GParamSpecUInt64 = @ptrCast(p);
        return c.g_param_spec_uint64(name, null, null, d.minimum, d.maximum, d.default_value, flags);
    }
    return null;
}

fn installProps(oc: *c.GObjectClass) void {
    const ec: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_ref(engine.viewType())));
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    for (props, 0..) |name, i| {
        const id: c.guint = @intCast(i + 1);
        const spec = if (std.mem.eql(u8, name, "favicon"))
            c.g_param_spec_pointer(name, null, null, ro)
        else if (std.mem.eql(u8, name, "theme-color"))
            c.g_param_spec_boxed(name, null, null, c.gdk_rgba_get_type(), ro)
        else if (std.mem.eql(u8, name, "is-ephemeral"))
            c.g_param_spec_boolean(name, null, null, 0, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_STATIC_STRINGS)
        else if (c.g_object_class_find_property(ec, name)) |p| copySpec(name, p) else null;
        if (spec) |s| c.g_object_class_install_property(oc, id, s);
    }
}

fn propIndex(name: []const u8) ?usize {
    for (props, 0..) |p, i| if (std.mem.eql(u8, p, name)) return i;
    return null;
}

pub fn imageSurface(image: ?*c.WebKitImage) ?*c.cairo_surface_t {
    const img = image orelse return null;
    const bytes = c.webkit_image_as_bytes(img) orelse return null;
    var size: usize = 0;
    const data = c.g_bytes_get_data(bytes, &size);
    const s = c.cairo_image_surface_create_for_data(@ptrCast(@constCast(data)), c.CAIRO_FORMAT_ARGB32, c.webkit_image_get_width(img), c.webkit_image_get_height(img), @intCast(c.webkit_image_get_stride(img)));
    _ = c.cairo_surface_set_user_data(s, &surface_key, bytes, releaseBytes);
    return s;
}

pub fn favicon(v: *View) ?*c.cairo_surface_t {
    if (v.priv.favicon) |s| return s;
    const web = v.priv.web orelse return null;
    const list = engineFn("webkit_web_view_get_page_icons")(@ptrCast(web)) orelse return null;
    var best: ?*c.WebKitImage = null;
    var size: c_int = 0;
    var i: c.guint = 0;
    while (i < c.webkit_image_list_get_length(list)) : (i += 1) {
        const img = c.webkit_image_list_get(list, i);
        if (c.webkit_image_get_width(img) > size) {
            size = c.webkit_image_get_width(img);
            best = img;
        }
    }
    v.priv.favicon = imageSurface(best);
    return v.priv.favicon;
}

pub fn isEphemeral(v: *View) bool {
    const web = v.priv.web orelse return false;
    const session = engineFn("webkit_web_view_get_network_session")(@ptrCast(web)) orelse return false;
    return c.webkit_network_session_is_ephemeral(session) != 0;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, value: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = of(o).priv;
    const name = props[id - 1];
    if (p.web) |web| {
        if (spec.*.flags & c.G_PARAM_CONSTRUCT_ONLY != 0) return;
        c.g_object_set_property(web, name, value);
        return;
    }
    if (std.mem.eql(u8, name, "is-ephemeral")) {
        if (c.g_value_get_boolean(value) == 0) return;
        if (p.n == MAX_CONSTRUCT) return;
        var session = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&session, c.webkit_network_session_get_type());
        const eph = c.webkit_network_session_new_ephemeral();
        c.g_value_take_object(&session, eph);
        p.names[p.n] = "network-session";
        p.values[p.n] = session;
        p.n += 1;
        return;
    }
    if (p.n == MAX_CONSTRUCT) return;
    var copy: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&copy, c.G_VALUE_TYPE(value));
    c.g_value_copy(value, &copy);
    if (std.mem.eql(u8, name, "related-view")) {
        const related = toEngine(c.g_value_get_object(&copy));
        c.g_value_unset(&copy);
        if (related == null) return;
        _ = c.g_value_init(&copy, engine.viewType());
        c.g_value_set_object(&copy, related);
    }
    p.names[p.n] = name;
    p.values[p.n] = copy;
    p.n += 1;
}

fn getProperty(o: [*c]c.GObject, id: c.guint, value: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const v = of(o);
    const name = props[id - 1];
    const web = v.priv.web orelse return;
    if (std.mem.eql(u8, name, "favicon")) return c.g_value_set_pointer(value, favicon(v));
    if (std.mem.eql(u8, name, "is-ephemeral")) return c.g_value_set_boolean(value, @intFromBool(isEphemeral(v)));
    if (std.mem.eql(u8, name, "theme-color")) {
        var color: c.WebKitColor = undefined;
        if (engineFn("webkit_web_view_get_theme_color")(@ptrCast(web), &color) == 0) return c.g_value_set_boxed(value, null);
        const rgba: c.GdkRGBA = .{ .red = color.red, .green = color.green, .blue = color.blue, .alpha = color.alpha };
        return c.g_value_set_boxed(value, &rgba);
    }
    c.g_object_get_property(web, name, value);
}

fn notify(_: ?*c.GObject, spec: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const v = of(data);
    const name = std.mem.span(spec.?.name);
    if (std.mem.eql(u8, name, "page-icons")) {
        if (v.priv.favicon) |s| c.cairo_surface_destroy(s);
        v.priv.favicon = null;
        return c.g_object_notify(@ptrCast(v), "favicon");
    }
    if (propIndex(name) != null) c.g_object_notify(@ptrCast(v), spec.?.name);
}

fn noop() callconv(.c) void {}

fn convertArg(dst: *c.GValue, src: [*c]const c.GValue) void {
    const t = c.G_VALUE_TYPE(src);
    if (t == c.webkit_rectangle_get_type()) {
        _ = c.g_value_init(dst, c.gdk_rectangle_get_type());
        return c.g_value_set_boxed(dst, c.g_value_get_boxed(src));
    }
    if (c.g_type_is_a(t, engine.viewType()) != 0) {
        _ = c.g_value_init(dst, viewType());
        return c.g_value_set_object(dst, toProxy(c.g_value_get_object(src)));
    }
    _ = c.g_value_init(dst, t);
    c.g_value_copy(src, dst);
}

fn emit(v: *View, index: usize, n: usize, params: [*c]const c.GValue, ret: [*c]c.GValue) void {
    const id = signal_ids[index];
    if (id == 0) return;
    var args = std.mem.zeroes([8]c.GValue);
    _ = c.g_value_init(&args[0], viewType());
    c.g_value_set_object(&args[0], v);
    var count: usize = 1;
    var i: usize = 1;
    while (i < n and count < args.len) : (i += 1) {
        if ((index == CONTEXT_MENU and i == 2) or (index == OPTION_MENU and i == 2)) {
            _ = c.g_value_init(&args[count], c.gdk_event_get_type());
            count += 1;
        }
        convertArg(&args[count], &params[i]);
        count += 1;
    }
    defer for (args[0..count]) |*a| c.g_value_unset(a);
    if (ret == null) return c.g_signal_emitv(&args, id, 0, null);
    var out = std.mem.zeroes(c.GValue);
    var q: c.GSignalQuery = undefined;
    c.g_signal_query(id, &q);
    _ = c.g_value_init(&out, q.return_type & ~@as(c.GType, c.G_SIGNAL_TYPE_STATIC_SCOPE));
    defer c.g_value_unset(&out);
    c.g_signal_emitv(&args, id, 0, &out);
    if (index == CREATE) return c.g_value_set_object(ret, toEngine(c.g_value_get_object(&out)));
    c.g_value_copy(&out, ret);
}

fn relayMarshal(_: ?*c.GClosure, ret: [*c]c.GValue, n: c.guint, params: [*c]const c.GValue, hint: c.gpointer, data: c.gpointer) callconv(.c) void {
    const v = of(data);
    const engine_id = @as(*c.GSignalInvocationHint, @ptrCast(@alignCast(hint))).signal_id;
    const index = std.mem.indexOfScalar(c.guint, &engine_ids, engine_id) orelse return;
    emit(v, index, n, params, ret);
    if (index == TERMINATED and c.g_value_get_enum(&params[1]) == c.WEBKIT_WEB_PROCESS_CRASHED) {
        var handled: c.gboolean = 0;
        c.g_signal_emit(v, signal_ids[CRASHED], 0, &handled);
    }
}

fn connectRelays(v: *View) void {
    const web = v.priv.web.?;
    for (signals, 0..) |s, i| {
        if (i >= RELAYED and i != CONTEXT_MENU and i != OPTION_MENU) continue;
        engine_ids[i] = c.g_signal_lookup(s.name, engine.viewType());
        if (engine_ids[i] == 0) continue;
        const closure = c.g_cclosure_new(@ptrCast(&noop), null, null);
        c.g_closure_set_meta_marshal(closure, v, relayMarshal);
        _ = c.g_signal_connect_closure(web, s.name, closure, 0);
    }
    _ = c.g_signal_connect_data(web, "notify", @ptrCast(&notify), v, null, 0);
}

const PRINT_SCRIPT = "window.print = function () { window.webkit.messageHandlers.fotonePrint.postMessage(0); };";

fn printHook(v: *View) void {
    const ucm = engineFn("webkit_web_view_get_user_content_manager")(@ptrCast(v.priv.web)) orelse return;
    if (engineFn("webkit_user_content_manager_register_script_message_handler")(ucm, "fotonePrint", null) == 0) return;
    const script = c.webkit_user_script_new(PRINT_SCRIPT, c.WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, null, null);
    defer c.webkit_user_script_unref(script);
    c.webkit_user_content_manager_add_script(ucm, script);
    _ = c.g_signal_connect_data(ucm, "script-message-received::fotonePrint", @ptrCast(&printRequested), v, null, 0);
}

fn printRequested(_: ?*c.WebKitUserContentManager, _: ?*c.JSCValue, data: c.gpointer) callconv(.c) void {
    const v = of(data);
    const op = extra.webkit_print_operation_new(@ptrCast(v)) orelse return;
    defer c.g_object_unref(op);
    if (!emitPrint(v, op)) _ = extra.webkit_print_operation_run_dialog(@ptrCast(@alignCast(op)), null);
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    parent_class.?.constructed.?(o);
    const v = of(o);
    const p = v.priv;
    var names: [MAX_CONSTRUCT + 1][*c]const u8 = undefined;
    var values = std.mem.zeroes([MAX_CONSTRUCT + 1]c.GValue);
    const d = display();
    names[0] = "display";
    _ = c.g_value_init(&values[0], c.G_TYPE_OBJECT);
    c.g_value_set_object(&values[0], d);
    var k: usize = 0;
    while (k < p.n) : (k += 1) {
        names[k + 1] = p.names[k];
        values[k + 1] = p.values[k];
    }
    const total = p.n + 1;
    p.web = c.g_object_new_with_properties(engine.viewType(), total, &names, &values);
    for (values[0..total]) |*val| c.g_value_unset(val);
    p.n = 0;
    c.g_object_set_qdata(p.web, proxy_quark, v);
    connectRelays(v);
    printHook(v);
    p.toplevel = c.wpe_display_create_toplevel(d, 1);
    p.view = engineFn("webkit_web_view_get_wpe_view")(@ptrCast(p.web));
    if (p.view) |w| c.fotone_view_set_frame_func(w, frame, v, null);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const p = of(o).priv;
    if (p.web) |web| {
        _ = c.g_signal_handlers_disconnect_matched(web, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, of(o));
        if (engineFn("webkit_web_view_get_user_content_manager")(@ptrCast(web))) |ucm| _ = c.g_signal_handlers_disconnect_matched(ucm, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, of(o));
        c.g_object_set_qdata(web, proxy_quark, null);
        if (p.view) |w| c.fotone_view_set_frame_func(w, null, null, null);
        c.g_object_unref(web);
    }
    p.web = null;
    p.view = null;
    if (p.toplevel) |t| c.g_object_unref(t);
    p.toplevel = null;
    if (p.surface) |s| c.cairo_surface_destroy(s);
    p.surface = null;
    if (p.favicon) |s| c.cairo_surface_destroy(s);
    p.favicon = null;
    parent_class.?.dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const p = of(o).priv;
    for (p.values[0..p.n]) |*val| c.g_value_unset(val);
    c.g_free(p);
    parent_class.?.finalize.?(o);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    proxy_quark = c.g_quark_from_static_string("fotone-webkit2gtk-view");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    oc.constructed = constructed;
    oc.dispose = dispose;
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    installProps(oc);
    installSignals(c.G_TYPE_FROM_CLASS(klass));
}

pub const PrintDone = print3.Done;

pub fn print(view: ?*c.GObject, parent: ?*c.GtkWindow, settings: ?*c.GtkPrintSettings, setup: ?*c.GtkPageSetup, dialog: bool, done: PrintDone, data: c.gpointer) bool {
    if (!isA(view, viewType())) return false;
    const v = of(view);
    const web = v.priv.web orelse return false;
    const top = c.gtk_widget_get_toplevel(@ptrCast(v));
    const window: ?*c.GtkWindow = parent orelse if (top != null and c.gtk_widget_is_toplevel(top) != 0) @ptrCast(top) else null;
    print3.run(@ptrCast(v), @ptrCast(web), window, settings, setup, dialog, done, data);
    return true;
}

pub fn showDevtools(_: ?*c.GObject) void {}

pub fn emitPrint(v: *View, op: *c.GObject) bool {
    var handled: c.gboolean = 0;
    c.g_signal_emit(v, signal_ids[PRINT], 0, op, &handled);
    return handled != 0;
}

pub fn emitColorChooser(v: *View, request: *c.GObject) bool {
    var handled: c.gboolean = 0;
    c.g_signal_emit(v, signal_ids[COLOR_CHOOSER], 0, request, &handled);
    return handled != 0;
}

export fn webkit_web_view_get_type() c.GType {
    return viewType();
}

export fn webkit_web_view_base_get_type() c.GType {
    return baseType();
}

test "class layouts match WebKitGTK 4.1" {
    try std.testing.expectEqual(@as(usize, 1008), @sizeOf(BaseClass));
    try std.testing.expectEqual(@as(usize, 1232), @sizeOf(ViewClass));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Base));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(View));
}

test "modifier masks map to WPE modifiers" {
    try std.testing.expectEqual(@as(c_uint, c.WPE_MODIFIER_KEYBOARD_CONTROL | c.WPE_MODIFIER_KEYBOARD_ALT), modifiers(c.GDK_CONTROL_MASK | c.GDK_MOD1_MASK));
    try std.testing.expectEqual(@as(c_uint, 0), modifiers(0));
}

const wrapped =
    \\call_async_javascript_function call_async_javascript_function_finish can_execute_editing_command
    \\can_execute_editing_command_finish can_go_back can_go_forward can_show_mime_type download_uri
    \\evaluate_javascript evaluate_javascript_finish execute_editing_command execute_editing_command_with_argument
    \\get_automation_presentation_type get_back_forward_list get_camera_capture_state get_context
    \\get_custom_charset get_default_content_security_policy get_display_capture_state get_editor_state
    \\get_estimated_load_progress get_find_controller get_input_method_context get_is_muted
    \\get_is_web_process_responsive get_main_resource get_microphone_capture_state
    \\get_page_id get_session_state get_settings get_snapshot get_title get_tls_info get_uri
    \\get_user_content_manager get_web_extension_mode get_website_policies get_window_properties
    \\get_zoom_level go_back go_forward go_to_back_forward_list_item is_controlled_by_automation
    \\is_editable is_immersive_mode_enabled is_loading is_playing_audio leave_immersive_mode
    \\load_alternate_html load_bytes load_html load_plain_text load_request load_uri reload
    \\reload_bypass_cache restore_session_state save save_finish save_to_file save_to_file_finish
    \\send_message_to_page send_message_to_page_finish set_camera_capture_state set_cors_allowlist
    \\set_custom_charset set_display_capture_state set_editable set_input_method_context set_is_muted
    \\set_microphone_capture_state set_settings set_zoom_level stop_loading terminate_web_process try_close
;

const returning_views = [_][:0]const u8{
    "webkit_find_controller_get_web_view",
    "webkit_download_get_web_view",
    "webkit_uri_scheme_request_get_web_view",
};

comptime {
    @setEvalBranchQuota(1000000);
    var it = std.mem.tokenizeAny(u8, wrapped, " \n");
    while (it.next()) |n| engine.Wrap(c, @This(), std.fmt.comptimePrint("webkit_web_view_{s}", .{n})).exportIt();
    for (returning_views) |n| engine.Wrap(c, @This(), n).exportIt();
}

fn newWith(name: [*c]const u8, value: ?*anyopaque) ?*c.GtkWidget {
    return @ptrCast(@alignCast(c.g_object_new(viewType(), name, value, @as([*c]const u8, null))));
}

export fn webkit_web_view_new() ?*c.GtkWidget {
    return @ptrCast(@alignCast(c.g_object_new(viewType(), @as([*c]const u8, null))));
}

export fn webkit_web_view_new_with_context(context: ?*c.WebKitWebContext) ?*c.GtkWidget {
    return newWith("web-context", context);
}

export fn webkit_web_view_new_with_related_view(related: ?*View) ?*c.GtkWidget {
    return newWith("related-view", related);
}

export fn webkit_web_view_new_with_settings(settings: ?*c.WebKitSettings) ?*c.GtkWidget {
    return newWith("settings", settings);
}

export fn webkit_web_view_new_with_user_content_manager(ucm: ?*c.WebKitUserContentManager) ?*c.GtkWidget {
    return newWith("user-content-manager", ucm);
}

export fn webkit_web_view_get_favicon(v: *View) ?*c.cairo_surface_t {
    return favicon(v);
}

export fn webkit_web_view_is_ephemeral(v: *View) c.gboolean {
    return @intFromBool(isEphemeral(v));
}

export fn webkit_web_view_get_background_color(v: *View, rgba: *c.GdkRGBA) void {
    var color: c.WebKitColor = undefined;
    engineFn("webkit_web_view_get_background_color")(@ptrCast(v.priv.web), &color);
    rgba.* = .{ .red = color.red, .green = color.green, .blue = color.blue, .alpha = color.alpha };
}

export fn webkit_web_view_set_background_color(v: *View, rgba: *const c.GdkRGBA) void {
    var color: c.WebKitColor = .{ .red = rgba.red, .green = rgba.green, .blue = rgba.blue, .alpha = rgba.alpha };
    engineFn("webkit_web_view_set_background_color")(@ptrCast(v.priv.web), &color);
}

export fn webkit_web_view_get_theme_color(v: *View, rgba: *c.GdkRGBA) c.gboolean {
    var color: c.WebKitColor = undefined;
    if (engineFn("webkit_web_view_get_theme_color")(@ptrCast(v.priv.web), &color) == 0) return 0;
    rgba.* = .{ .red = color.red, .green = color.green, .blue = color.blue, .alpha = color.alpha };
    return 1;
}

export fn webkit_web_view_get_snapshot_finish(v: *View, result: ?*c.GAsyncResult, err: [*c][*c]c.GError) ?*c.cairo_surface_t {
    const img = engineFn("webkit_web_view_get_snapshot_finish")(@ptrCast(v.priv.web), result, err) orelse return null;
    defer c.g_object_unref(img);
    const s = imageSurface(img) orelse return null;
    const copy = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, c.cairo_image_surface_get_width(s), c.cairo_image_surface_get_height(s));
    const cr = c.cairo_create(copy);
    c.cairo_set_source_surface(cr, s, 0, 0);
    c.cairo_paint(cr);
    c.cairo_destroy(cr);
    c.cairo_surface_destroy(s);
    return copy;
}

export fn webkit_web_view_get_javascript_global_context(_: *View) ?*anyopaque {
    return null;
}
