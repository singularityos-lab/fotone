const std = @import("std");
const c = @import("c.zig").c;
const settings = @import("settings.zig");
const accent = @import("accent.zig");
const memory = @import("memory.zig");
const ui = @import("ui.zig");
const webapp = @import("webapp.zig");
const print = @import("print.zig");
const devtools = @import("devtools.zig");
const privacy = @import("privacy.zig");
const passwords = @import("passwords.zig");
const perms = @import("perms.zig");
const a11y = @import("a11y.zig");
const dnr = @import("dnr.zig");
const widevine = @import("widevine.zig");
const sites = @import("sites.zig");
const files = @import("files.zig");
const authn = @import("authn.zig");
const pagetr = @import("translate.zig");
const material = @import("material.zig");
const extensions = @import("extensions.zig");

comptime {
    _ = authn;
    _ = pagetr;
    _ = material;
}

pub const WebView = extern struct {
    parent: c.GtkWidget,
    web: ?*c.WebKitWebView,
    view: ?*c.WPEView,
    toplevel: ?*c.WPEToplevel,
    texture: ?*c.GdkTexture,
    clock: ?*c.GdkFrameClock,
    paint: c.gulong,
    fresh: c.gboolean,
    pinch_base: f64,
    swipe_dx: f64,
    hidden_at: i64,
    state: ?*c.WebKitWebViewSessionState,
    holding: c.gboolean,
    last_x: f64,
    last_y: f64,
    fs_window: ?*c.GtkWindow,
    transparent: c.gboolean,
    passwords: c.gboolean,
    surface: ?*c.GdkSurface,
    rescale: c.gulong,
};

const Class = extern struct {
    parent: c.GtkWidgetClass,
};

var parent_class: ?*c.GtkWidgetClass = null;
var type_id: c.GType = 0;
var shared: ?*c.WPEDisplay = null;
var views: ?*c.GPtrArray = null;
var watch: c.guint = 0;

fn of(p: anytype) *WebView {
    return @ptrCast(@alignCast(p));
}

fn widget(w: *WebView) *c.GtkWidget {
    return &w.parent;
}

pub fn getType() c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(&type_id)) != 0) {
        const t = c.g_type_register_static_simple(c.gtk_widget_get_type(), c.g_intern_static_string("SitWebView"), @sizeOf(Class), classInit, @sizeOf(WebView), instanceInit, 0);
        a11y.implement(t);
        c.g_once_init_leave_pointer(@ptrCast(&type_id), @ptrFromInt(t));
    }
    return type_id;
}

fn display() ?*c.WPEDisplay {
    if (shared) |d| return d;
    const d = c.fotone_display_new(null);
    if (c.gdk_display_get_default()) |gd| {
        const formats = c.gdk_display_get_dmabuf_formats(gd);
        var i: usize = 0;
        while (i < c.gdk_dmabuf_formats_get_n_formats(formats)) : (i += 1) {
            var fourcc: u32 = 0;
            var modifier: u64 = 0;
            c.gdk_dmabuf_formats_get_format(formats, i, &fourcc, &modifier);
            c.fotone_display_add_format(d, fourcc, modifier);
        }
    }
    devtools.prepare();
    privacy.identify();
    var err: [*c]c.GError = null;
    if (c.wpe_display_connect(d, &err) == 0) {
        std.log.warn("fotone display: {s}", .{if (err) |e| std.mem.span(e.*.message) else "unknown error"});
        c.g_clear_error(&err);
    }
    settings.follow(d);
    accent.follow(d);
    shared = d;
    return d;
}

fn releaseBuffer(data: c.gpointer) callconv(.c) void {
    c.g_object_unref(data);
}

fn dmabufTexture(w: *WebView, buffer: *c.WPEBuffer) ?*c.GdkTexture {
    const d: *c.WPEBufferDMABuf = @ptrCast(buffer);
    const b = c.gdk_dmabuf_texture_builder_new();
    defer c.g_object_unref(b);
    c.gdk_dmabuf_texture_builder_set_display(b, c.gtk_widget_get_display(widget(w)));
    c.gdk_dmabuf_texture_builder_set_width(b, @intCast(c.wpe_buffer_get_width(buffer)));
    c.gdk_dmabuf_texture_builder_set_height(b, @intCast(c.wpe_buffer_get_height(buffer)));
    c.gdk_dmabuf_texture_builder_set_fourcc(b, c.wpe_buffer_dma_buf_get_format(d));
    c.gdk_dmabuf_texture_builder_set_modifier(b, c.wpe_buffer_dma_buf_get_modifier(d));
    const n = c.wpe_buffer_dma_buf_get_n_planes(d);
    c.gdk_dmabuf_texture_builder_set_n_planes(b, n);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        c.gdk_dmabuf_texture_builder_set_fd(b, i, c.wpe_buffer_dma_buf_get_fd(d, i));
        c.gdk_dmabuf_texture_builder_set_stride(b, i, c.wpe_buffer_dma_buf_get_stride(d, i));
        c.gdk_dmabuf_texture_builder_set_offset(b, i, c.wpe_buffer_dma_buf_get_offset(d, i));
    }
    var err: [*c]c.GError = null;
    const t = c.gdk_dmabuf_texture_builder_build(b, releaseBuffer, c.g_object_ref(buffer), &err);
    if (t == null) {
        std.log.warn("fotone dmabuf: {s}", .{if (err) |e| std.mem.span(e.*.message) else "unknown error"});
        c.g_clear_error(&err);
        c.g_object_unref(buffer);
    }
    return t;
}

fn shmTexture(buffer: *c.WPEBuffer) ?*c.GdkTexture {
    const s: *c.WPEBufferSHM = @ptrCast(buffer);
    if (c.wpe_buffer_shm_get_format(s) != c.WPE_PIXEL_FORMAT_ARGB8888) return null;
    const src = c.wpe_buffer_shm_get_data(s) orelse return null;
    var size: usize = 0;
    const data = c.g_bytes_get_data(src, &size);
    const copy = c.g_bytes_new(data, size);
    defer c.g_bytes_unref(copy);
    return c.gdk_memory_texture_new(c.wpe_buffer_get_width(buffer), c.wpe_buffer_get_height(buffer), c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, copy, c.wpe_buffer_shm_get_stride(s));
}

fn isA(o: anytype, t: c.GType) bool {
    return c.g_type_check_instance_is_a(@ptrCast(@alignCast(o)), t) != 0;
}

fn frame(view: ?*c.WPEView, buffer: ?*c.WPEBuffer, data: c.gpointer) callconv(.c) void {
    const w = of(data);
    const b = buffer orelse return;
    if (w.holding != 0) {
        c.fotone_view_frame_presented(view);
        return;
    }
    const t = if (isA(b, c.wpe_buffer_dma_buf_get_type())) dmabufTexture(w, b) else if (isA(b, c.wpe_buffer_shm_get_type())) shmTexture(b) else null;
    if (t == null) {
        c.fotone_view_frame_presented(view);
        return;
    }
    if (w.texture) |old| c.g_object_unref(old);
    w.texture = t;
    w.fresh = 1;
    c.gtk_widget_queue_draw(widget(w));
}

fn afterPaint(_: ?*c.GdkFrameClock, data: c.gpointer) callconv(.c) void {
    const w = of(data);
    if (w.fresh == 0) return;
    w.fresh = 0;
    if (w.view) |v| c.fotone_view_frame_presented(v);
}

fn snapshot(wd: [*c]c.GtkWidget, s: ?*c.GtkSnapshot) callconv(.c) void {
    const w = of(wd);
    const t = w.texture orelse return;
    const r: c.graphene_rect_t = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(c.gtk_widget_get_width(wd)), .height = @floatFromInt(c.gtk_widget_get_height(wd)) },
    };
    c.gtk_snapshot_append_texture(s, t, &r);
}

fn scaleOf(wd: [*c]c.GtkWidget) f64 {
    if (c.gtk_widget_get_native(wd)) |n| {
        if (c.gtk_native_get_surface(n)) |s| return c.gdk_surface_get_scale(s);
    }
    return @floatFromInt(c.gtk_widget_get_scale_factor(wd));
}

fn sizeAllocate(wd: [*c]c.GtkWidget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
    const w = of(wd);
    if (w.toplevel) |t| c.fotone_toplevel_configure(t, width, height, scaleOf(wd));
}

fn scaleChanged(_: ?*c.GObject, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const w = of(data);
    const wd = widget(w);
    if (w.toplevel) |t| c.fotone_toplevel_configure(t, c.gtk_widget_get_width(wd), c.gtk_widget_get_height(wd), scaleOf(wd));
}

fn sleep(w: *WebView) void {
    const web = w.web orelse return;
    if (w.state != null or w.texture == null) return;
    w.state = c.webkit_web_view_get_session_state(web);
    w.holding = 1;
    c.webkit_web_view_load_uri(web, "about:blank");
}

fn wake(w: *WebView) void {
    const web = w.web orelse return;
    const state = w.state orelse return;
    w.state = null;
    c.webkit_web_view_restore_session_state(web, state);
    c.webkit_web_view_session_state_unref(state);
    const item = c.webkit_back_forward_list_get_current_item(c.webkit_web_view_get_back_forward_list(web));
    if (item != null) c.webkit_web_view_go_to_back_forward_list_item(web, item) else w.holding = 0;
}

fn materialRead(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const v = c.webkit_web_view_evaluate_javascript_finish(@ptrCast(@alignCast(src)), res, null) orelse return;
    defer c.g_object_unref(v);
    const text = c.jsc_value_to_string(v);
    defer c.g_free(text);
    if (text == null) return;
    const w = of(data);
    if (material.apply(widget(w), material.parse(std.mem.span(text)))) sit_web_view_set_transparent(w, 1);
}

fn loadChanged(web: ?*c.WebKitWebView, event: c.WebKitLoadEvent, data: c.gpointer) callconv(.c) void {
    const w = of(data);
    if (event == c.WEBKIT_LOAD_COMMITTED and w.state == null) w.holding = 0;
    if (event != c.WEBKIT_LOAD_FINISHED) return;
    if (perms.appOf(web) != null and w.transparent == 0) c.webkit_web_view_evaluate_javascript(web, material.query, -1, null, null, null, materialRead, w);
    if (w.passwords != 0) passwords.fill(web orelse return);
}

fn submitForm(web: ?*c.WebKitWebView, req: ?*c.WebKitFormSubmissionRequest, data: c.gpointer) callconv(.c) void {
    const w = of(data);
    if (w.passwords == 0) return;
    passwords.submitted(web orelse return, req orelse return, ui.windowOf(widget(w)));
}

fn check(_: c.gpointer) callconv(.c) c.gboolean {
    const list = views orelse return 1;
    const now = c.g_get_monotonic_time();
    const p = memory.pressure();
    var awake: usize = 0;
    var i: c.guint = 0;
    while (i < list.*.len) : (i += 1) {
        const w = of(list.*.pdata[i]);
        if (w.hidden_at > 0 and memory.shouldSleep(now - w.hidden_at, p)) sleep(w);
        if (w.state == null) awake += 1;
    }
    const limit = memory.budget();
    while (awake > limit) : (awake -= 1) {
        const oldest = oldestHidden(list) orelse break;
        sleep(oldest);
        if (oldest.state == null) break;
    }
    return 1;
}

fn oldestHidden(list: *c.GPtrArray) ?*WebView {
    var best: ?*WebView = null;
    var i: c.guint = 0;
    while (i < list.*.len) : (i += 1) {
        const w = of(list.*.pdata[i]);
        if (w.hidden_at == 0 or w.state != null or w.texture == null) continue;
        if (best == null or w.hidden_at < best.?.hidden_at) best = w;
    }
    return best;
}

fn track(w: *WebView) void {
    if (views == null) views = c.g_ptr_array_new();
    c.g_ptr_array_add(views, w);
    if (watch == 0) watch = c.g_timeout_add_seconds(10, check, null);
}

fn map(wd: [*c]c.GtkWidget) callconv(.c) void {
    parent_class.?.map.?(wd);
    const w = of(wd);
    w.hidden_at = 0;
    wake(w);
    w.clock = c.gtk_widget_get_frame_clock(wd);
    if (w.clock) |k| w.paint = c.g_signal_connect_data(k, "after-paint", @ptrCast(&afterPaint), w, null, 0);
    if (c.gtk_widget_get_native(wd)) |n| w.surface = c.gtk_native_get_surface(n);
    if (w.surface) |sf| w.rescale = c.g_signal_connect_data(sf, "notify::scale", @ptrCast(&scaleChanged), w, null, 0);
    if (w.view) |v| c.wpe_view_set_toplevel(v, w.toplevel);
}

fn unmap(wd: [*c]c.GtkWidget) callconv(.c) void {
    const w = of(wd);
    if (w.view) |v| c.wpe_view_set_toplevel(v, null);
    if (w.clock) |k| c.g_signal_handler_disconnect(k, w.paint);
    w.clock = null;
    w.paint = 0;
    if (w.surface) |sf| c.g_signal_handler_disconnect(sf, w.rescale);
    w.surface = null;
    w.rescale = 0;
    w.hidden_at = c.g_get_monotonic_time();
    parent_class.?.unmap.?(wd);
}

fn modifiers(state: c.GdkModifierType) c.WPEModifiers {
    const pairs = [_][2]c_uint{
        .{ c.GDK_CONTROL_MASK, c.WPE_MODIFIER_KEYBOARD_CONTROL },
        .{ c.GDK_SHIFT_MASK, c.WPE_MODIFIER_KEYBOARD_SHIFT },
        .{ c.GDK_ALT_MASK, c.WPE_MODIFIER_KEYBOARD_ALT },
        .{ c.GDK_META_MASK | c.GDK_SUPER_MASK, c.WPE_MODIFIER_KEYBOARD_META },
        .{ c.GDK_LOCK_MASK, c.WPE_MODIFIER_KEYBOARD_CAPS_LOCK },
        .{ c.GDK_BUTTON1_MASK, c.WPE_MODIFIER_POINTER_BUTTON1 },
        .{ c.GDK_BUTTON2_MASK, c.WPE_MODIFIER_POINTER_BUTTON2 },
        .{ c.GDK_BUTTON3_MASK, c.WPE_MODIFIER_POINTER_BUTTON3 },
        .{ c.GDK_BUTTON4_MASK, c.WPE_MODIFIER_POINTER_BUTTON4 },
        .{ c.GDK_BUTTON5_MASK, c.WPE_MODIFIER_POINTER_BUTTON5 },
    };
    var m: c_uint = 0;
    for (pairs) |p| {
        if (state & p[0] != 0) m |= p[1];
    }
    return m;
}

fn source(ev: ?*c.GdkEvent) c.WPEInputSource {
    const dev = c.gdk_event_get_device(ev) orelse return c.WPE_INPUT_SOURCE_MOUSE;
    return switch (c.gdk_device_get_source(dev)) {
        c.GDK_SOURCE_TOUCHPAD => c.WPE_INPUT_SOURCE_TOUCHPAD,
        c.GDK_SOURCE_TOUCHSCREEN => c.WPE_INPUT_SOURCE_TOUCHSCREEN,
        c.GDK_SOURCE_PEN => c.WPE_INPUT_SOURCE_PEN,
        c.GDK_SOURCE_KEYBOARD => c.WPE_INPUT_SOURCE_KEYBOARD,
        c.GDK_SOURCE_TRACKPOINT => c.WPE_INPUT_SOURCE_TRACKPOINT,
        else => c.WPE_INPUT_SOURCE_MOUSE,
    };
}

fn position(wd: [*c]c.GtkWidget, ev: ?*c.GdkEvent, x: *f64, y: *f64) bool {
    if (c.gdk_event_get_position(ev, x, y) == 0) return false;
    const n = c.gtk_widget_get_native(wd) orelse return false;
    var nx: f64 = 0;
    var ny: f64 = 0;
    c.gtk_native_get_surface_transform(n, &nx, &ny);
    const in: c.graphene_point_t = .{ .x = @floatCast(x.* - nx), .y = @floatCast(y.* - ny) };
    var out: c.graphene_point_t = undefined;
    if (c.gtk_widget_compute_point(@ptrCast(@alignCast(n)), wd, &in, &out) == 0) return false;
    x.* = out.x;
    y.* = out.y;
    return true;
}

fn translate(w: *WebView, ev: ?*c.GdkEvent) ?*c.WPEEvent {
    const v = w.view orelse return null;
    const wd = widget(w);
    const time = c.gdk_event_get_time(ev);
    const mods = modifiers(c.gdk_event_get_modifier_state(ev));
    const src = source(ev);
    var x: f64 = 0;
    var y: f64 = 0;
    const kind = c.gdk_event_get_event_type(ev);
    switch (kind) {
        c.GDK_MOTION_NOTIFY, c.GDK_ENTER_NOTIFY, c.GDK_LEAVE_NOTIFY => {
            _ = position(wd, ev, &x, &y);
            w.last_x = x;
            w.last_y = y;
            const t: c.WPEEventType = switch (kind) {
                c.GDK_ENTER_NOTIFY => c.WPE_EVENT_POINTER_ENTER,
                c.GDK_LEAVE_NOTIFY => c.WPE_EVENT_POINTER_LEAVE,
                else => c.WPE_EVENT_POINTER_MOVE,
            };
            return c.wpe_event_pointer_move_new(t, v, src, time, mods, x, y, 0, 0);
        },
        c.GDK_BUTTON_PRESS, c.GDK_BUTTON_RELEASE => {
            if (!position(wd, ev, &x, &y)) return null;
            const down = kind == c.GDK_BUTTON_PRESS;
            if (down) _ = c.gtk_widget_grab_focus(wd);
            const t: c.WPEEventType = if (down) c.WPE_EVENT_POINTER_DOWN else c.WPE_EVENT_POINTER_UP;
            const button = c.gdk_button_event_get_button(ev);
            const count = if (down) c.wpe_view_compute_press_count(v, x, y, button, time) else 0;
            return c.wpe_event_pointer_button_new(t, v, src, time, mods, button, x, y, count);
        },
        c.GDK_SCROLL => {
            _ = position(wd, ev, &x, &y);
            var dx: f64 = 0;
            var dy: f64 = 0;
            switch (c.gdk_scroll_event_get_direction(ev)) {
                c.GDK_SCROLL_UP => dy = -1,
                c.GDK_SCROLL_DOWN => dy = 1,
                c.GDK_SCROLL_LEFT => dx = -1,
                c.GDK_SCROLL_RIGHT => dx = 1,
                else => c.gdk_scroll_event_get_deltas(ev, &dx, &dy),
            }
            const precise = c.gdk_scroll_event_get_unit(ev) == c.GDK_SCROLL_UNIT_SURFACE;
            const stop = c.gdk_scroll_event_is_stop(ev) != 0;
            return c.wpe_event_scroll_new(v, src, time, mods, -dx, -dy, @intFromBool(precise), @intFromBool(stop), x, y);
        },
        c.GDK_KEY_PRESS, c.GDK_KEY_RELEASE => {
            const t: c.WPEEventType = if (kind == c.GDK_KEY_PRESS) c.WPE_EVENT_KEYBOARD_KEY_DOWN else c.WPE_EVENT_KEYBOARD_KEY_UP;
            return c.wpe_event_keyboard_new(t, v, c.WPE_INPUT_SOURCE_KEYBOARD, time, mods, c.gdk_key_event_get_keycode(ev), c.gdk_key_event_get_keyval(ev));
        },
        c.GDK_TOUCH_BEGIN, c.GDK_TOUCH_UPDATE, c.GDK_TOUCH_END, c.GDK_TOUCH_CANCEL => {
            if (!position(wd, ev, &x, &y)) return null;
            const t: c.WPEEventType = switch (kind) {
                c.GDK_TOUCH_BEGIN => c.WPE_EVENT_TOUCH_DOWN,
                c.GDK_TOUCH_UPDATE => c.WPE_EVENT_TOUCH_MOVE,
                c.GDK_TOUCH_END => c.WPE_EVENT_TOUCH_UP,
                else => c.WPE_EVENT_TOUCH_CANCEL,
            };
            const seq: u32 = @truncate(@intFromPtr(c.gdk_event_get_event_sequence(ev)));
            return c.wpe_event_touch_new(t, v, src, time, mods, seq, x, y);
        },
        else => return null,
    }
}

pub fn clampZoom(z: f64) f64 {
    return std.math.clamp(z, 0.3, 5.0);
}

pub const Swipe = enum { none, back, forward };

pub fn swipeResult(dx: f64) Swipe {
    if (dx > 120) return .back;
    if (dx < -120) return .forward;
    return .none;
}

fn gesture(w: *WebView, ev: ?*c.GdkEvent) bool {
    const web = w.web orelse return false;
    const phase = c.gdk_touchpad_event_get_gesture_phase(ev);
    switch (c.gdk_event_get_event_type(ev)) {
        c.GDK_TOUCHPAD_PINCH => {
            if (c.gdk_touchpad_event_get_n_fingers(ev) != 2) return false;
            if (phase == c.GDK_TOUCHPAD_GESTURE_PHASE_BEGIN) w.pinch_base = c.webkit_web_view_get_zoom_level(web);
            if (phase == c.GDK_TOUCHPAD_GESTURE_PHASE_UPDATE and w.pinch_base > 0) c.webkit_web_view_set_zoom_level(web, clampZoom(w.pinch_base * c.gdk_touchpad_event_get_pinch_scale(ev)));
            return true;
        },
        c.GDK_TOUCHPAD_SWIPE => {
            if (c.gdk_touchpad_event_get_n_fingers(ev) != 3) return false;
            var dx: f64 = 0;
            var dy: f64 = 0;
            c.gdk_touchpad_event_get_deltas(ev, &dx, &dy);
            if (phase == c.GDK_TOUCHPAD_GESTURE_PHASE_BEGIN) w.swipe_dx = 0;
            w.swipe_dx += dx;
            if (phase == c.GDK_TOUCHPAD_GESTURE_PHASE_END) switch (swipeResult(w.swipe_dx)) {
                .back => if (c.webkit_web_view_can_go_back(web) != 0) c.webkit_web_view_go_back(web),
                .forward => if (c.webkit_web_view_can_go_forward(web) != 0) c.webkit_web_view_go_forward(web),
                .none => {},
            };
            return true;
        },
        else => return false,
    }
}

fn onEvent(_: ?*c.GtkEventControllerLegacy, ev: ?*c.GdkEvent, data: c.gpointer) callconv(.c) c.gboolean {
    const w = of(data);
    if (gesture(w, ev)) return 1;
    const e = translate(w, ev) orelse return 0;
    defer c.wpe_event_unref(e);
    c.wpe_view_event(w.view, e);
    return 1;
}

fn focusIn(_: ?*c.GtkEventControllerFocus, data: c.gpointer) callconv(.c) void {
    if (of(data).view) |v| c.wpe_view_focus_in(v);
}

fn focusOut(_: ?*c.GtkEventControllerFocus, data: c.gpointer) callconv(.c) void {
    if (of(data).view) |v| c.wpe_view_focus_out(v);
}

fn instanceInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const w = of(inst);
    const wd = widget(w);
    c.gtk_widget_set_focusable(wd, 1);
    w.passwords = 1;
    c.gtk_widget_set_hexpand(wd, 1);
    c.gtk_widget_set_vexpand(wd, 1);

    const legacy = c.gtk_event_controller_legacy_new();
    _ = c.g_signal_connect_data(legacy, "event", @ptrCast(&onEvent), w, null, 0);
    c.gtk_widget_add_controller(wd, legacy);
    const focus = c.gtk_event_controller_focus_new();
    _ = c.g_signal_connect_data(focus, "enter", @ptrCast(&focusIn), w, null, 0);
    _ = c.g_signal_connect_data(focus, "leave", @ptrCast(&focusOut), w, null, 0);
    c.gtk_widget_add_controller(wd, focus);
}

fn attach(w: *WebView) void {
    const d = display();
    if (w.web == null) w.web = @ptrCast(@alignCast(c.g_object_new(c.webkit_web_view_get_type(), "display", d, @as([*c]const u8, null))));
    sites.hook(w.web.?);
    if (c.webkit_web_view_get_settings(w.web)) |st| {
        c.webkit_settings_set_enable_encrypted_media(st, 1);
        settings.enable(st);
    }
    w.toplevel = c.wpe_display_create_toplevel(d, 1);
    w.view = c.webkit_web_view_get_wpe_view(w.web);
    if (w.view) |v| {
        c.fotone_view_set_frame_func(v, frame, w, null);
        c.fotone_view_set_accessible_func(v, a11y.plugged, w, null);
    }
    _ = c.g_signal_connect_data(w.web, "load-changed", @ptrCast(&loadChanged), w, null, 0);
    const after = c.G_CONNECT_AFTER;
    _ = c.g_signal_connect_data(w.web, "script-dialog", @ptrCast(&ui.scriptDialog), w, null, after);
    _ = c.g_signal_connect_data(w.web, "run-file-chooser", @ptrCast(&ui.runFileChooser), w, null, after);
    _ = c.g_signal_connect_data(w.web, "authenticate", @ptrCast(&ui.authenticate), w, null, after);
    _ = c.g_signal_connect_data(w.web, "show-option-menu", @ptrCast(&ui.showOptionMenu), w, null, after);
    _ = c.g_signal_connect_data(w.web, "context-menu", @ptrCast(&contextMenu), w, null, after);
    _ = c.g_signal_connect_data(w.web, "show-notification", @ptrCast(&ui.showNotification), w, null, after);
    _ = c.g_signal_connect_data(w.web, "permission-request", @ptrCast(&ui.permissionRequest), w, null, 0);
    _ = c.g_signal_connect_data(w.web, "submit-form", @ptrCast(&submitForm), w, null, after);
    printHook(w);
    if (c.webkit_web_view_get_user_content_manager(w.web)) |ucm| {
        dnr.track(ucm);
        extensions.track(ucm);
    }
    devtools.apply(w.web.?);
    c.g_object_set_data(@ptrCast(w.web), "fotone-widget", w);
    widevine.hook(w.web.?);
    files.hook(w.web.?);
    c.fotone_toplevel_set_fullscreen_func(w.toplevel, fullscreen, w, null);
    if (w.transparent != 0) applyBackground(w);
    track(w);
}

const PRINT_SCRIPT = "window.print = function () { window.webkit.messageHandlers.fotonePrint.postMessage(0); };";

var print_signal: c.guint = 0;

fn printHook(w: *WebView) void {
    const ucm = c.webkit_web_view_get_user_content_manager(w.web) orelse return;
    if (c.webkit_user_content_manager_register_script_message_handler(ucm, "fotonePrint", null) == 0) return;
    const script = c.webkit_user_script_new(PRINT_SCRIPT, c.WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, null, null);
    defer c.webkit_user_script_unref(script);
    c.webkit_user_content_manager_add_script(ucm, script);
    _ = c.g_signal_connect_data(ucm, "script-message-received::fotonePrint", @ptrCast(&printRequested), w, null, 0);
}

fn printRequested(_: ?*c.WebKitUserContentManager, _: ?*c.JSCValue, data: c.gpointer) callconv(.c) void {
    const w = of(data);
    var handled: c.gboolean = 0;
    c.g_signal_emit(w, print_signal, 0, &handled);
    if (handled == 0) print.run(widget(w), w.web orelse return, ui.windowOf(widget(w)), null, null, true, null, null);
}

fn inspect(_: ?*c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    _ = sit_web_view_show_devtools(of(data));
}

fn replaceInspect(w: *WebView, menu: *c.WebKitContextMenu) void {
    var l = c.webkit_context_menu_get_items(menu);
    while (l) |node| {
        l = node.*.next;
        const item: *c.WebKitContextMenuItem = @ptrCast(@alignCast(node.*.data));
        if (c.webkit_context_menu_item_get_stock_action(item) == c.WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT) c.webkit_context_menu_remove(menu, item);
    }
    if (!devtools.available()) return;
    const action = c.g_simple_action_new("fotone-inspect", null);
    defer c.g_object_unref(action);
    _ = c.g_signal_connect_data(action, "activate", @ptrCast(&inspect), w, null, 0);
    c.webkit_context_menu_append(menu, c.webkit_context_menu_item_new_separator());
    c.webkit_context_menu_append(menu, c.webkit_context_menu_item_new_from_gaction(@ptrCast(action), c.g_dgettext("fotone", "Inspect"), null));
}

fn contextMenu(web: ?*c.WebKitWebView, menu: ?*c.WebKitContextMenu, hit: ?*c.WebKitHitTestResult, data: c.gpointer) callconv(.c) c.gboolean {
    const w = of(data);
    if (menu) |m| replaceInspect(w, m);
    const link = if (hit) |h| (if (c.webkit_hit_test_result_context_is_link(h) != 0) c.webkit_hit_test_result_get_link_uri(h) else null) else null;
    const uri = if (link != null) link else c.webkit_web_view_get_uri(web);
    const selected = if (hit) |h| c.webkit_hit_test_result_context_is_selection(h) != 0 else false;
    const editable = if (hit) |h| c.webkit_hit_test_result_context_is_editable(h) != 0 else false;
    return @intFromBool(ui.contextMenu(widget(w), menu orelse return 0, w.last_x, w.last_y, uri, if (selected) web else null, if (editable) web else null, if (!selected and !editable and link == null) web else null));
}

fn fullscreened(win: ?*c.GtkWindow, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const w = of(data);
    if (w.toplevel) |t| c.fotone_toplevel_set_fullscreened(t, c.gtk_window_is_fullscreen(win));
}

fn fullscreen(_: ?*c.WPEToplevel, on: c.gboolean, data: c.gpointer) callconv(.c) c.gboolean {
    const w = of(data);
    const root = c.gtk_widget_get_root(widget(w)) orelse return 0;
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(root)), c.gtk_window_get_type()) == 0) return 0;
    const win: *c.GtkWindow = @ptrCast(@alignCast(root));
    if (w.fs_window != win) {
        forgetWindow(w);
        w.fs_window = win;
        c.g_object_add_weak_pointer(@ptrCast(win), @ptrCast(&w.fs_window));
        _ = c.g_signal_connect_data(win, "notify::fullscreened", @ptrCast(&fullscreened), w, null, 0);
    }
    if (on != 0) c.gtk_window_fullscreen(win) else c.gtk_window_unfullscreen(win);
    return 1;
}

fn forgetWindow(w: *WebView) void {
    const win = w.fs_window orelse return;
    _ = c.g_signal_handlers_disconnect_matched(win, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, w);
    c.g_object_remove_weak_pointer(@ptrCast(win), @ptrCast(&w.fs_window));
    w.fs_window = null;
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    @as(*c.GObjectClass, @ptrCast(parent_class.?)).constructed.?(o);
    attach(of(o));
}

const PROP_WEB_VIEW = 1;
const PROP_TRANSPARENT = 2;
const PROP_PASSWORDS = 3;

fn applyBackground(w: *WebView) void {
    const web = w.web orelse return;
    var color: c.WebKitColor = if (w.transparent != 0) .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 } else .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
    c.webkit_web_view_set_background_color(web, &color);
    if (w.transparent != 0) c.gtk_widget_add_css_class(widget(w), "transparent") else c.gtk_widget_remove_css_class(widget(w), "transparent");
}

fn setProperty(o: [*c]c.GObject, id: c.guint, value: [*c]const c.GValue, _: ?*c.GParamSpec) callconv(.c) void {
    const w = of(o);
    switch (id) {
        PROP_WEB_VIEW => if (c.g_value_dup_object(value)) |web| {
            w.web = @ptrCast(@alignCast(web));
        },
        PROP_TRANSPARENT => sit_web_view_set_transparent(w, c.g_value_get_boolean(value)),
        PROP_PASSWORDS => sit_web_view_set_passwords(w, c.g_value_get_boolean(value)),
        else => {},
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, value: [*c]c.GValue, _: ?*c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_WEB_VIEW => c.g_value_set_object(value, of(o).web),
        PROP_TRANSPARENT => c.g_value_set_boolean(value, of(o).transparent),
        PROP_PASSWORDS => c.g_value_set_boolean(value, of(o).passwords),
        else => {},
    }
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const w = of(o);
    if (views) |list| _ = c.g_ptr_array_remove(list, w);
    a11y.clear(widget(w));
    if (w.state) |st| c.webkit_web_view_session_state_unref(st);
    w.state = null;
    if (w.view) |v| {
        c.fotone_view_set_frame_func(v, null, null, null);
        c.fotone_view_set_accessible_func(v, null, null, null);
        c.wpe_view_set_toplevel(v, null);
    }
    w.view = null;
    if (w.web) |p| {
        c.g_object_set_data(@ptrCast(p), "fotone-widget", null);
        _ = c.g_signal_handlers_disconnect_matched(p, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, w);
        if (c.webkit_web_view_get_user_content_manager(p)) |ucm| _ = c.g_signal_handlers_disconnect_matched(ucm, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, w);
        c.g_object_unref(p);
    }
    w.web = null;
    forgetWindow(w);
    if (w.toplevel) |p| {
        c.fotone_toplevel_set_fullscreen_func(p, null, null, null);
        c.g_object_unref(p);
    }
    w.toplevel = null;
    if (w.texture) |p| c.g_object_unref(p);
    w.texture = null;
    @as(*c.GObjectClass, @ptrCast(parent_class.?)).dispose.?(o);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    oc.dispose = dispose;
    oc.constructed = constructed;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_WEB_VIEW, c.g_param_spec_object("web-view", null, null, c.webkit_web_view_get_type(), c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PROP_PASSWORDS, c.g_param_spec_boolean("passwords", null, null, 1, c.G_PARAM_READWRITE | c.G_PARAM_EXPLICIT_NOTIFY | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PROP_TRANSPARENT, c.g_param_spec_boolean("transparent", null, null, 0, c.G_PARAM_READWRITE | c.G_PARAM_EXPLICIT_NOTIFY | c.G_PARAM_STATIC_STRINGS));
    print_signal = c.g_signal_new("print-requested", c.G_TYPE_FROM_CLASS(klass), c.G_SIGNAL_RUN_LAST, 0, c.g_signal_accumulator_true_handled, null, c.g_cclosure_marshal_generic, c.G_TYPE_BOOLEAN, 0);
    const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
    wc.snapshot = snapshot;
    wc.size_allocate = sizeAllocate;
    wc.map = map;
    wc.unmap = unmap;
    c.gtk_widget_class_set_css_name(wc, "webview");
}

pub export fn sit_web_view_get_type() c.GType {
    return getType();
}

pub export fn sit_web_view_new() [*c]c.GtkWidget {
    return @ptrCast(@alignCast(c.g_object_new(getType(), @as([*c]const u8, null))));
}

pub export fn sit_web_view_new_with_web_view(web: ?*c.WebKitWebView) [*c]c.GtkWidget {
    return @ptrCast(@alignCast(c.g_object_new(getType(), "web-view", web, @as([*c]const u8, null))));
}

pub export fn sit_web_view_get_display() ?*c.WPEDisplay {
    return display();
}

pub export fn sit_web_view_get_web_view(self: *WebView) ?*c.WebKitWebView {
    return self.web;
}

pub export fn sit_web_view_set_transparent(self: *WebView, transparent: c.gboolean) void {
    if ((self.transparent != 0) == (transparent != 0)) return;
    self.transparent = @intFromBool(transparent != 0);
    applyBackground(self);
    c.g_object_notify(@ptrCast(self), "transparent");
}

pub export fn sit_web_view_get_transparent(self: *WebView) c.gboolean {
    return self.transparent;
}

pub export fn sit_web_view_get_frame(self: *WebView) ?*c.GdkTexture {
    return self.texture;
}

pub export fn sit_web_view_set_passwords(self: *WebView, enabled: c.gboolean) void {
    if ((self.passwords != 0) == (enabled != 0)) return;
    self.passwords = @intFromBool(enabled != 0);
    c.g_object_notify(@ptrCast(self), "passwords");
}

pub export fn sit_web_view_get_passwords(self: *WebView) c.gboolean {
    return self.passwords;
}

pub export fn sit_web_view_new_for_web_app(id: [*:0]const u8) [*c]c.GtkWidget {
    const session = webapp.session(id);
    defer if (session) |s| c.g_object_unref(s);
    const web = c.g_object_new(c.webkit_web_view_get_type(), "display", display(), "network-session", session, @as([*c]const u8, null));
    defer c.g_object_unref(web);
    c.g_object_set_data_full(@ptrCast(@alignCast(web)), perms.APP_KEY, c.g_strdup(id), c.g_free);
    return sit_web_view_new_with_web_view(@ptrCast(@alignCast(web)));
}

pub export fn sit_web_view_install_web_app(self: *WebView, name: [*:0]const u8, err: [*c][*c]c.GError) ?[*:0]u8 {
    const web = self.web orelse return null;
    const uri = c.webkit_web_view_get_uri(web) orelse return null;
    const id = webapp.appId(uri) orelse return null;
    defer c.g_free(id);
    const texture = webapp.pageIcon(web);
    defer if (texture) |t| c.g_object_unref(t);
    return webapp.install(id, name, uri, texture, err);
}

pub export fn sit_web_view_print(self: *WebView, parent: ?*c.GtkWindow, ps: ?*c.GtkPrintSettings, setup: ?*c.GtkPageSetup, dialog: c.gboolean, done: ?print.Done, data: c.gpointer) void {
    const web = self.web orelse {
        if (done) |d| d(data, 0);
        return;
    };
    print.run(widget(self), web, parent orelse ui.windowOf(widget(self)), ps, setup, dialog != 0, done, data);
}

fn wrapWebView(web: *c.WebKitWebView) *c.GtkWidget {
    return sit_web_view_new_with_web_view(web);
}

pub export fn sit_web_view_show_devtools(self: *WebView) c.gboolean {
    const web = self.web orelse return 0;
    return @intFromBool(devtools.open(web, wrapWebView, display(), ui.windowOf(widget(self))));
}

pub export fn sit_web_view_install_extension(path: [*:0]const u8, err: [*c][*c]c.GError) [*c]u8 {
    const id = extensions.install(std.mem.span(path), display()) catch |e| {
        c.g_set_error(err, c.g_io_error_quark(), c.G_IO_ERROR_INVALID_DATA, "%s: %s", path, @errorName(e).ptr);
        return null;
    };
    return c.g_strdup(id.ptr);
}

pub export fn sit_web_view_remove_extension(id: [*:0]const u8) void {
    extensions.remove(std.mem.span(id));
}

pub export fn sit_web_view_install_rule_set(id: [*:0]const u8, rules: [*:0]const u8, done: dnr.Done, data: c.gpointer, err: [*c][*c]c.GError) c.gboolean {
    const r = dnr.install(id, std.mem.span(rules), done, data) catch {
        c.g_set_error_literal(err, c.g_io_error_quark(), c.G_IO_ERROR_INVALID_DATA, "the rules are not a declarativeNetRequest rule list");
        return 0;
    };
    r.deinit();
    return 1;
}

pub export fn sit_web_view_remove_rule_set(id: [*:0]const u8) void {
    dnr.remove(id);
}

pub export fn sit_web_view_translate(self: *WebView) void {
    pagetr.page(self.web orelse return);
}

pub export fn sit_web_view_load_uri(self: *WebView, uri: [*c]const u8) void {
    if (self.web) |p| c.webkit_web_view_load_uri(p, uri);
}

test {
    _ = files;
    _ = webapp;
    _ = print;
    _ = devtools;
    _ = privacy;
    _ = passwords;
    _ = settings;
    _ = accent;
    _ = memory;
    _ = @import("contacts.zig");
    _ = perms;
    _ = a11y;
    _ = dnr;
    _ = extensions;
    _ = widevine;
    _ = sites;
    _ = authn;
    _ = pagetr;
}

test "gestures clamp zoom and need a long swipe" {
    try std.testing.expectEqual(@as(f64, 5.0), clampZoom(9));
    try std.testing.expectEqual(@as(f64, 0.3), clampZoom(0.1));
    try std.testing.expectEqual(Swipe.back, swipeResult(200));
    try std.testing.expectEqual(Swipe.forward, swipeResult(-200));
    try std.testing.expectEqual(Swipe.none, swipeResult(40));
}

test "modifiers map onto the WPE bits" {
    try std.testing.expectEqual(@as(c.WPEModifiers, c.WPE_MODIFIER_KEYBOARD_CONTROL | c.WPE_MODIFIER_POINTER_BUTTON1), modifiers(c.GDK_CONTROL_MASK | c.GDK_BUTTON1_MASK));
    try std.testing.expectEqual(@as(c.WPEModifiers, c.WPE_MODIFIER_KEYBOARD_META), modifiers(c.GDK_SUPER_MASK));
}
