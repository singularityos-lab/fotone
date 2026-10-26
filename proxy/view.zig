const std = @import("std");
const c = @import("c.zig").c;
const engine = @import("engine");
const extra = @import("extra.zig");
const gtkonly = @import("gtkonly.zig");

const Fn = ?*const anyopaque;

pub const Base = extern struct {
    parent: c.GtkWidget,
    priv: ?*anyopaque,
};

pub const BaseClass = extern struct {
    parent: c.GtkWidgetClass,
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
    reserved: [31]Fn,
};

const MAX_CONSTRUCT = 16;

pub const Priv = extern struct {
    sit: ?*c.GtkWidget,
    web: ?*c.GObject,
    favicon: ?*c.GdkTexture,
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
    .{ .name = "print", .field = "print" },
    .{ .name = "resource-load-started", .field = "resource_load_started" },
    .{ .name = "enter-fullscreen", .field = "enter_fullscreen" },
    .{ .name = "leave-fullscreen", .field = "leave_fullscreen" },
    .{ .name = "run-file-chooser", .field = "run_file_chooser" },
    .{ .name = "context-menu", .field = "context_menu" },
    .{ .name = "context-menu-dismissed", .field = "context_menu_dismissed" },
    .{ .name = "submit-form", .field = "submit_form" },
    .{ .name = "insecure-content-detected", .field = "insecure_content_detected" },
    .{ .name = "web-process-terminated", .field = "web_process_terminated" },
    .{ .name = "authenticate", .field = "authenticate" },
    .{ .name = "show-notification", .field = "show_notification" },
    .{ .name = "run-color-chooser", .field = "run_color_chooser" },
    .{ .name = "show-option-menu", .field = "show_option_menu" },
    .{ .name = "user-message-received", .field = "user_message_received" },
    .{ .name = "query-permission-state", .field = "query_permission_state" },
};

const props = [_][:0]const u8{
    "web-context",                  "related-view",                    "settings",
    "user-content-manager",         "network-session",                 "title",
    "estimated-load-progress",      "favicon",                         "uri",
    "zoom-level",                   "is-loading",                      "is-playing-audio",
    "is-controlled-by-automation",  "automation-presentation-type",    "editable",
    "page-id",                      "is-muted",                        "website-policies",
    "is-web-process-responsive",    "camera-capture-state",            "microphone-capture-state",
    "display-capture-state",        "web-extension-mode",              "default-content-security-policy",
    "theme-color",                  "is-immersive-mode-enabled",
};

const CREATE = 3;
const PRINT = 11;
const COLOR_CHOOSER = 23;

var base_type: c.GType = 0;
var view_type: c.GType = 0;
var parent_class: ?*c.GObjectClass = null;
var signal_ids = [_]c.guint{0} ** signals.len;
var proxy_quark: c.GQuark = 0;

fn propIndex(name: []const u8) ?usize {
    for (props, 0..) |p, i| if (std.mem.eql(u8, p, name)) return i;
    return null;
}

pub fn baseType() c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(&base_type)) != 0) {
        const t = c.g_type_register_static_simple(c.gtk_widget_get_type(), c.g_intern_static_string("WebKitWebViewBase"), @sizeOf(BaseClass), baseClassInit, @sizeOf(Base), null, 0);
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

fn of(p: anytype) *View {
    return @ptrCast(@alignCast(p));
}

fn isA(o: ?*anyopaque, t: c.GType) bool {
    const p = o orelse return false;
    return c.g_type_check_instance_is_a(@ptrCast(@alignCast(p)), t) != 0;
}

pub fn toEngine(p: ?*anyopaque) ?*anyopaque {
    if (!isA(p, viewType())) return p;
    return of(p).priv.web;
}

pub fn sitOf(p: ?*anyopaque) ?*c.SitWebView {
    if (!isA(p, viewType())) return null;
    return @ptrCast(@alignCast(of(p).priv.sit));
}

pub const PrintDone = *const fn (c.gpointer, c.gboolean) callconv(.c) void;

pub fn print(view: ?*c.GObject, parent: ?*c.GtkWindow, settings: ?*c.GtkPrintSettings, setup: ?*c.GtkPageSetup, dialog: bool, done: PrintDone, data: c.gpointer) bool {
    const sit = sitOf(view) orelse return false;
    c.sit_web_view_print(sit, parent, settings, setup, @intFromBool(dialog), done, data);
    return true;
}

pub fn showDevtools(view: ?*c.GObject) void {
    if (sitOf(view)) |sit| _ = c.sit_web_view_show_devtools(sit);
}

fn printRequested(_: ?*c.GtkWidget, data: c.gpointer) callconv(.c) c.gboolean {
    const v = of(data);
    const op = extra.webkit_print_operation_new(@ptrCast(v)) orelse return 1;
    defer c.g_object_unref(op);
    var handled: c.gboolean = 0;
    c.g_signal_emit(v, signal_ids[PRINT], 0, op, &handled);
    if (handled == 0) _ = extra.webkit_print_operation_run_dialog(@ptrCast(@alignCast(op)), null);
    return 1;
}

pub fn toProxy(p: ?*anyopaque) ?*anyopaque {
    const o = p orelse return null;
    if (isA(o, viewType())) return o;
    return c.g_object_get_qdata(@ptrCast(@alignCast(o)), proxy_quark) orelse o;
}

fn baseGrabFocus(w: ?*c.GtkWidget) callconv(.c) c.gboolean {
    const child = c.gtk_widget_get_first_child(w) orelse return 0;
    return c.gtk_widget_grab_focus(child);
}

fn baseClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
    wc.grab_focus = baseGrabFocus;
    c.gtk_widget_class_set_layout_manager_type(wc, c.gtk_bin_layout_get_type());
    c.gtk_widget_class_set_css_name(wc, "webkitwebview");
}

fn instanceInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const v = of(inst);
    const p: *Priv = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Priv))));
    v.priv = p;
    v.parent.priv = null;
    c.gtk_widget_set_hexpand(@ptrCast(v), 1);
    c.gtk_widget_set_vexpand(@ptrCast(v), 1);
    c.gtk_widget_set_focusable(@ptrCast(v), 1);
}

fn objectHandled(_: ?*c.GSignalInvocationHint, ret: [*c]c.GValue, handler: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    const o = c.g_value_get_object(handler);
    c.g_value_set_object(ret, o);
    return @intFromBool(o == null);
}

fn mapType(t: c.GType) c.GType {
    const flag = t & c.G_SIGNAL_TYPE_STATIC_SCOPE;
    const bare = t & ~@as(c.GType, c.G_SIGNAL_TYPE_STATIC_SCOPE);
    if (bare == c.webkit_rectangle_get_type()) return c.gdk_rectangle_get_type() | flag;
    if (bare == engine.viewType()) return viewType() | flag;
    return t;
}

fn installSignals(itype: c.GType) void {
    const etype = engine.viewType();
    inline for (signals, 0..) |s, i| {
        const offset = @offsetOf(ViewClass, s.field);
        if (i == PRINT) {
            signal_ids[i] = c.g_signal_new(s.name, itype, c.G_SIGNAL_RUN_LAST, offset, c.g_signal_accumulator_true_handled, null, c.g_cclosure_marshal_generic, c.G_TYPE_BOOLEAN, 1, extra.printOperationType());
        } else if (i == COLOR_CHOOSER) {
            signal_ids[i] = c.g_signal_new(s.name, itype, c.G_SIGNAL_RUN_LAST, offset, c.g_signal_accumulator_true_handled, null, c.g_cclosure_marshal_generic, c.G_TYPE_BOOLEAN, 1, extra.colorChooserRequestType());
        } else {
            var q: c.GSignalQuery = undefined;
            c.g_signal_query(c.g_signal_lookup(s.name, etype), &q);
            if (q.signal_id != 0) {
                var types: [8]c.GType = undefined;
                var k: usize = 0;
                while (k < q.n_params) : (k += 1) types[k] = mapType(q.param_types[k]);
                const ret = if (i == CREATE) c.gtk_widget_get_type() else mapType(q.return_type);
                const closure = c.g_signal_type_cclosure_new(itype, offset);
                const acc: c.GSignalAccumulator = if (i == CREATE) objectHandled else if (q.return_type == c.G_TYPE_BOOLEAN) c.g_signal_accumulator_true_handled else null;
                signal_ids[i] = c.g_signal_newv(s.name, itype, q.signal_flags, closure, acc, null, c.g_cclosure_marshal_generic, ret, q.n_params, &types);
            }
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
    if (std.mem.eql(u8, kind, "GParamUInt")) {
        const d: *c.GParamSpecUInt = @ptrCast(p);
        return c.g_param_spec_uint(name, null, null, d.minimum, d.maximum, d.default_value, flags);
    }
    return null;
}

fn installProps(oc: *c.GObjectClass) void {
    const ec: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_ref(engine.viewType())));
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    for (props, 0..) |name, i| {
        const id: c.guint = @intCast(i + 1);
        const spec = if (std.mem.eql(u8, name, "favicon"))
            c.g_param_spec_object(name, null, null, c.gdk_texture_get_type(), ro)
        else if (std.mem.eql(u8, name, "theme-color"))
            c.g_param_spec_boxed(name, null, null, c.gdk_rgba_get_type(), ro)
        else if (c.g_object_class_find_property(ec, name)) |p| copySpec(name, p) else null;
        if (spec) |s| c.g_object_class_install_property(oc, id, s);
    }
}

pub fn colorToRgba(color: c.WebKitColor) c.GdkRGBA {
    return .{ .red = @floatCast(color.red), .green = @floatCast(color.green), .blue = @floatCast(color.blue), .alpha = @floatCast(color.alpha) };
}

pub fn rgbaToColor(rgba: c.GdkRGBA) c.WebKitColor {
    return .{ .red = rgba.red, .green = rgba.green, .blue = rgba.blue, .alpha = rgba.alpha };
}

pub fn imageTexture(image: ?*c.WebKitImage) ?*c.GdkTexture {
    const img = image orelse return null;
    const bytes = c.webkit_image_as_bytes(img) orelse return null;
    defer c.g_bytes_unref(bytes);
    return c.gdk_memory_texture_new(c.webkit_image_get_width(img), c.webkit_image_get_height(img), c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, c.webkit_image_get_stride(img));
}

fn engineFn(comptime name: [:0]const u8) *const @TypeOf(@field(c, name)) {
    return engine.lookup(name, @TypeOf(@field(c, name)));
}

pub fn favicon(v: *View) ?*c.GdkTexture {
    if (v.priv.favicon) |t| return t;
    const web = v.priv.web orelse return null;
    const list = engineFn("webkit_web_view_get_page_icons")(@ptrCast(web)) orelse return null;
    var best: ?*c.WebKitImage = null;
    var size: c_int = 0;
    var i: c.guint = 0;
    while (i < c.webkit_image_list_get_length(list)) : (i += 1) {
        const img = c.webkit_image_list_get(list, i);
        const w = c.webkit_image_get_width(img);
        if (w > size) {
            size = w;
            best = img;
        }
    }
    v.priv.favicon = imageTexture(best);
    return v.priv.favicon;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, value: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = of(o).priv;
    const name = props[id - 1];
    if (p.web) |web| {
        if (spec.*.flags & c.G_PARAM_CONSTRUCT_ONLY != 0) return;
        c.g_object_set_property(web, name, value);
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
    if (std.mem.eql(u8, name, "favicon")) {
        c.g_value_set_object(value, favicon(v));
        return;
    }
    if (std.mem.eql(u8, name, "theme-color")) {
        var color: c.WebKitColor = undefined;
        if (engineFn("webkit_web_view_get_theme_color")(@ptrCast(web), &color) == 0) return c.g_value_set_boxed(value, null);
        const rgba = colorToRgba(color);
        c.g_value_set_boxed(value, &rgba);
        return;
    }
    c.g_object_get_property(web, name, value);
}

fn notify(_: ?*c.GObject, spec: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const v = of(data);
    const name = std.mem.span(spec.?.name);
    if (std.mem.eql(u8, name, "page-icons")) {
        if (v.priv.favicon) |t| c.g_object_unref(t);
        v.priv.favicon = null;
        c.g_object_notify(@ptrCast(v), "favicon");
        return;
    }
    if (propIndex(name) != null) c.g_object_notify(@ptrCast(v), spec.?.name);
}

var engine_ids = [_]c.guint{0} ** signals.len;

fn noop() callconv(.c) void {}

fn convertArg(dst: *c.GValue, src: [*c]const c.GValue) void {
    const t = c.G_VALUE_TYPE(src);
    if (t == c.webkit_rectangle_get_type()) {
        _ = c.g_value_init(dst, c.gdk_rectangle_get_type());
        c.g_value_set_boxed(dst, c.g_value_get_boxed(src));
        return;
    }
    if (c.g_type_is_a(t, engine.viewType()) != 0) {
        _ = c.g_value_init(dst, viewType());
        c.g_value_set_object(dst, toProxy(c.g_value_get_object(src)));
        return;
    }
    _ = c.g_value_init(dst, t);
    c.g_value_copy(src, dst);
}

fn relayMarshal(_: ?*c.GClosure, ret: [*c]c.GValue, n: c.guint, params: [*c]const c.GValue, hint: c.gpointer, data: c.gpointer) callconv(.c) void {
    const v = of(data);
    const engine_id = @as(*c.GSignalInvocationHint, @ptrCast(@alignCast(hint))).signal_id;
    const index = std.mem.indexOfScalar(c.guint, &engine_ids, engine_id) orelse return;
    const id = signal_ids[index];
    if (id == 0) return;
    var args = std.mem.zeroes([8]c.GValue);
    _ = c.g_value_init(&args[0], viewType());
    c.g_value_set_object(&args[0], v);
    var i: usize = 1;
    while (i < n and i < args.len) : (i += 1) convertArg(&args[i], &params[i]);
    defer for (args[0..i]) |*a| c.g_value_unset(a);
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

fn connectRelays(v: *View) void {
    const web = v.priv.web.?;
    for (signals, 0..) |s, i| {
        if (i == PRINT or i == COLOR_CHOOSER) continue;
        engine_ids[i] = c.g_signal_lookup(s.name, engine.viewType());
        if (engine_ids[i] == 0) continue;
        const closure = c.g_cclosure_new(@ptrCast(&noop), null, null);
        c.g_closure_set_meta_marshal(closure, v, relayMarshal);
        _ = c.g_signal_connect_closure(web, s.name, closure, 0);
    }
    _ = c.g_signal_connect_data(web, "notify", @ptrCast(&notify), v, null, 0);
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    parent_class.?.constructed.?(o);
    const v = of(o);
    const p = v.priv;
    var names: [MAX_CONSTRUCT + 1][*c]const u8 = undefined;
    var values = std.mem.zeroes([MAX_CONSTRUCT + 1]c.GValue);
    names[0] = "display";
    _ = c.g_value_init(&values[0], c.G_TYPE_OBJECT);
    c.g_value_set_object(&values[0], c.sit_web_view_get_display());
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
    c.g_object_set_data(@ptrCast(v), "fotone-engine-web-view", p.web);
    connectRelays(v);
    const sit = c.sit_web_view_new_with_web_view(@ptrCast(p.web));
    c.gtk_widget_set_parent(sit, @ptrCast(v));
    p.sit = sit;
    _ = c.g_signal_connect_data(sit, "print-requested", @ptrCast(&printRequested), v, null, 0);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const p = of(o).priv;
    if (p.sit) |s| c.gtk_widget_unparent(s);
    p.sit = null;
    if (p.web) |web| {
        _ = c.g_signal_handlers_disconnect_matched(web, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, of(o));
        c.g_object_set_qdata(web, proxy_quark, null);
        c.g_object_set_data(@ptrCast(of(o)), "fotone-engine-web-view", null);
        c.g_object_unref(web);
    }
    p.web = null;
    if (p.favicon) |t| c.g_object_unref(t);
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
    proxy_quark = c.g_quark_from_static_string("fotone-webkitgtk-view");
    _ = gtkonly.webkit_favicon_database_get_type();
    const oc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    oc.constructed = constructed;
    oc.dispose = dispose;
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    installProps(oc);
    installSignals(c.G_TYPE_FROM_CLASS(klass));
}

const wrapped =
    \\call_async_javascript_function call_async_javascript_function_finish can_execute_editing_command
    \\can_execute_editing_command_finish can_go_back can_go_forward can_show_mime_type download_uri
    \\evaluate_javascript evaluate_javascript_finish execute_editing_command execute_editing_command_with_argument
    \\get_automation_presentation_type get_back_forward_list get_camera_capture_state get_context
    \\get_custom_charset get_default_content_security_policy get_display_capture_state get_editor_state
    \\get_estimated_load_progress get_find_controller get_input_method_context get_is_muted
    \\get_is_web_process_responsive get_main_resource get_microphone_capture_state get_network_session
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

export fn webkit_web_view_get_type() c.GType {
    return viewType();
}

export fn webkit_web_view_base_get_type() c.GType {
    return baseType();
}

export fn webkit_web_view_new() ?*c.GtkWidget {
    return @ptrCast(@alignCast(c.g_object_new(viewType(), @as([*c]const u8, null))));
}

export fn webkit_web_view_get_favicon(v: *View) ?*c.GdkTexture {
    return favicon(v);
}

export fn webkit_web_view_get_background_color(v: *View, rgba: *c.GdkRGBA) void {
    var color: c.WebKitColor = undefined;
    engineFn("webkit_web_view_get_background_color")(@ptrCast(v.priv.web), &color);
    rgba.* = colorToRgba(color);
}

export fn webkit_web_view_set_background_color(v: *View, rgba: *const c.GdkRGBA) void {
    var color = rgbaToColor(rgba.*);
    engineFn("webkit_web_view_set_background_color")(@ptrCast(v.priv.web), &color);
}

export fn webkit_web_view_get_theme_color(v: *View, rgba: *c.GdkRGBA) c.gboolean {
    var color: c.WebKitColor = undefined;
    if (engineFn("webkit_web_view_get_theme_color")(@ptrCast(v.priv.web), &color) == 0) return 0;
    rgba.* = colorToRgba(color);
    return 1;
}

export fn webkit_web_view_get_snapshot_finish(v: *View, result: ?*c.GAsyncResult, err: [*c][*c]c.GError) ?*c.GdkTexture {
    const img = engineFn("webkit_web_view_get_snapshot_finish")(@ptrCast(v.priv.web), result, err) orelse return null;
    defer c.g_object_unref(img);
    return imageTexture(img);
}

export fn webkit_web_view_get_inspector(v: *View) ?*c.GObject {
    return extra.inspectorFor(@ptrCast(v));
}

test "class layouts match WebKitGTK 6.0" {
    try std.testing.expectEqual(@as(usize, 440), @sizeOf(BaseClass));
    try std.testing.expectEqual(@as(usize, 912), @sizeOf(ViewClass));
    try std.testing.expectEqual(@sizeOf(c.GtkWidget) + 16, @sizeOf(View));
}

test "colors convert between the GTK and WPE structs" {
    const rgba = colorToRgba(.{ .red = 0.25, .green = 0.5, .blue = 0.75, .alpha = 1 });
    try std.testing.expectEqual(@as(f32, 0.5), rgba.green);
    try std.testing.expectEqual(@as(f64, 0.75), rgbaToColor(rgba).blue);
}
