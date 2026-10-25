const std = @import("std");
const c = @import("c.zig").c;
const proxy_view = @import("view.zig");

const Priv = struct {
    view: ?*c.GObject = null,
    rgba: c.GdkRGBA = std.mem.zeroes(c.GdkRGBA),
    settings: ?*c.GtkPrintSettings = null,
    setup: ?*c.GtkPageSetup = null,
};

const Object = extern struct {
    parent: c.GObject,
    priv: *Priv,
};

const ObjectClass = extern struct {
    parent: c.GObjectClass,
};

const PRINT_PRINT = 0;
const PRINT_CANCEL = 1;

var print_type: c.GType = 0;
var chooser_type: c.GType = 0;
var inspector_type: c.GType = 0;
var inspector_quark: c.GQuark = 0;
var print_finished: c.guint = 0;
var chooser_finished: c.guint = 0;

fn of(p: anytype) *Object {
    return @ptrCast(@alignCast(p));
}

fn register(t: *c.GType, name: [*:0]const u8, init: c.GClassInitFunc) c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(t)) != 0) {
        const id = c.g_type_register_static_simple(c.G_TYPE_OBJECT, c.g_intern_static_string(name), @sizeOf(ObjectClass), init, @sizeOf(Object), instanceInit, 0);
        c.g_once_init_leave_pointer(@ptrCast(t), @ptrFromInt(id));
    }
    return t.*;
}

fn instanceInit(o: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: *Priv = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Priv))));
    p.* = .{};
    of(o).priv = p;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const x = of(o);
    if (x.priv.view) |v| c.g_object_remove_weak_pointer(v, @ptrCast(&x.priv.view));
    if (x.priv.settings) |s| c.g_object_unref(s);
    if (x.priv.setup) |s| c.g_object_unref(s);
    c.g_free(x.priv);
    const parent: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_peek(c.G_TYPE_OBJECT)));
    parent.finalize.?(o);
}

const PROP_WEB_VIEW = 1;
const PROP_PRINT_SETTINGS = 2;
const PROP_PAGE_SETUP = 3;
const PROP_RGBA = 4;
const PROP_ATTACHED_HEIGHT = 5;
const PROP_CAN_ATTACH = 6;
const PROP_INSPECTED_URI = 7;

fn setProperty(o: [*c]c.GObject, id: c.guint, value: [*c]const c.GValue, _: ?*c.GParamSpec) callconv(.c) void {
    const x = of(o);
    switch (id) {
        PROP_WEB_VIEW => {
            if (x.priv.view) |v| c.g_object_remove_weak_pointer(v, @ptrCast(&x.priv.view));
            x.priv.view = @ptrCast(@alignCast(c.g_value_get_object(value)));
            if (x.priv.view) |v| c.g_object_add_weak_pointer(v, @ptrCast(&x.priv.view));
        },
        PROP_PRINT_SETTINGS => webkit_print_operation_set_print_settings(x, @ptrCast(@alignCast(c.g_value_get_object(value)))),
        PROP_PAGE_SETUP => webkit_print_operation_set_page_setup(x, @ptrCast(@alignCast(c.g_value_get_object(value)))),
        PROP_RGBA => if (c.g_value_get_boxed(value)) |b| {
            x.priv.rgba = @as(*const c.GdkRGBA, @ptrCast(@alignCast(b))).*;
        },
        else => {},
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, value: [*c]c.GValue, _: ?*c.GParamSpec) callconv(.c) void {
    const x = of(o);
    switch (id) {
        PROP_WEB_VIEW => c.g_value_set_object(value, x.priv.view),
        PROP_PRINT_SETTINGS => c.g_value_set_object(value, x.priv.settings),
        PROP_PAGE_SETUP => c.g_value_set_object(value, x.priv.setup),
        PROP_RGBA => c.g_value_set_boxed(value, &x.priv.rgba),
        PROP_ATTACHED_HEIGHT => c.g_value_set_uint(value, 0),
        PROP_CAN_ATTACH => c.g_value_set_boolean(value, 0),
        PROP_INSPECTED_URI => c.g_value_set_string(value, webkit_web_inspector_get_inspected_uri(x)),
        else => {},
    }
}

fn baseInit(klass: c.gpointer) *c.GObjectClass {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    return oc;
}

const RW = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;

fn printClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc = baseInit(klass);
    c.g_object_class_install_property(oc, PROP_WEB_VIEW, c.g_param_spec_object("web-view", null, null, proxy_view.viewType(), RW | c.G_PARAM_CONSTRUCT_ONLY));
    c.g_object_class_install_property(oc, PROP_PRINT_SETTINGS, c.g_param_spec_object("print-settings", null, null, c.gtk_print_settings_get_type(), RW));
    c.g_object_class_install_property(oc, PROP_PAGE_SETUP, c.g_param_spec_object("page-setup", null, null, c.gtk_page_setup_get_type(), RW));
    const t = c.G_TYPE_FROM_CLASS(klass);
    print_finished = c.g_signal_new("finished", t, c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 0);
    _ = c.g_signal_new("failed", t, c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 1, c.g_error_get_type());
}

fn chooserClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc = baseInit(klass);
    c.g_object_class_install_property(oc, PROP_RGBA, c.g_param_spec_boxed("rgba", null, null, c.gdk_rgba_get_type(), RW | c.G_PARAM_CONSTRUCT));
    chooser_finished = c.g_signal_new("finished", c.G_TYPE_FROM_CLASS(klass), c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 0);
}

fn inspectorClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc = baseInit(klass);
    const RO = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, PROP_ATTACHED_HEIGHT, c.g_param_spec_uint("attached-height", null, null, 0, std.math.maxInt(c.guint), 0, RO));
    c.g_object_class_install_property(oc, PROP_CAN_ATTACH, c.g_param_spec_boolean("can-attach", null, null, 0, RO));
    c.g_object_class_install_property(oc, PROP_INSPECTED_URI, c.g_param_spec_string("inspected-uri", null, null, null, RO));
    const t = c.G_TYPE_FROM_CLASS(klass);
    for ([_][*:0]const u8{ "open-window", "attach", "detach", "bring-to-front" }) |n| _ = c.g_signal_new(n, t, c.G_SIGNAL_RUN_LAST, 0, c.g_signal_accumulator_true_handled, null, c.g_cclosure_marshal_generic, c.G_TYPE_BOOLEAN, 0);
    for ([_][*:0]const u8{"closed"}) |n| _ = c.g_signal_new(n, t, c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 0);
}

pub fn printOperationType() c.GType {
    return register(&print_type, "WebKitPrintOperation", printClassInit);
}

pub fn colorChooserRequestType() c.GType {
    return register(&chooser_type, "WebKitColorChooserRequest", chooserClassInit);
}

pub fn inspectorType() c.GType {
    return register(&inspector_type, "WebKitWebInspector", inspectorClassInit);
}

fn withView(t: c.GType, view: ?*c.GObject) *Object {
    const x = of(c.g_object_new(t, @as([*c]const u8, null)));
    x.priv.view = view;
    if (view) |v| c.g_object_add_weak_pointer(v, @ptrCast(&x.priv.view));
    return x;
}

pub fn inspectorFor(view: ?*c.GObject) ?*c.GObject {
    const v = view orelse return null;
    if (inspector_quark == 0) inspector_quark = c.g_quark_from_static_string("fotone-webkitgtk-inspector");
    if (c.g_object_get_qdata(v, inspector_quark)) |i| return @ptrCast(@alignCast(i));
    const i = withView(inspectorType(), v);
    c.g_object_set_qdata_full(v, inspector_quark, i, c.g_object_unref);
    return &i.parent;
}

export fn webkit_print_operation_get_type() c.GType {
    return printOperationType();
}

pub export fn webkit_print_operation_new(view: ?*c.GObject) ?*c.GObject {
    return &withView(printOperationType(), view).parent;
}

export fn webkit_print_operation_get_print_settings(op: *Object) ?*c.GtkPrintSettings {
    return op.priv.settings;
}

export fn webkit_print_operation_set_print_settings(op: *Object, s: ?*c.GtkPrintSettings) void {
    if (op.priv.settings) |old| c.g_object_unref(old);
    op.priv.settings = if (s) |n| @ptrCast(@alignCast(c.g_object_ref(n))) else null;
}

export fn webkit_print_operation_get_page_setup(op: *Object) ?*c.GtkPageSetup {
    return op.priv.setup;
}

export fn webkit_print_operation_set_page_setup(op: *Object, s: ?*c.GtkPageSetup) void {
    if (op.priv.setup) |old| c.g_object_unref(old);
    op.priv.setup = if (s) |n| @ptrCast(@alignCast(c.g_object_ref(n))) else null;
}

const Wait = struct {
    loop: *c.GMainLoop,
    ok: c.gboolean = 0,
};

fn waited(data: c.gpointer, ok: c.gboolean) callconv(.c) void {
    const w: *Wait = @ptrCast(@alignCast(data));
    w.ok = ok;
    c.g_main_loop_quit(w.loop);
}

pub export fn webkit_print_operation_run_dialog(op: *Object, parent: ?*c.GtkWindow) c_int {
    defer c.g_signal_emit(op, print_finished, 0);
    const sit = proxy_view.sitOf(op.priv.view) orelse return PRINT_CANCEL;
    var w = Wait{ .loop = c.g_main_loop_new(null, 0).? };
    defer c.g_main_loop_unref(w.loop);
    c.sit_web_view_print(sit, parent, op.priv.settings, op.priv.setup, 1, waited, &w);
    c.g_main_loop_run(w.loop);
    return if (w.ok != 0) PRINT_PRINT else PRINT_CANCEL;
}

fn printedAsync(data: c.gpointer, _: c.gboolean) callconv(.c) void {
    const op: *Object = @ptrCast(@alignCast(data));
    c.g_signal_emit(op, print_finished, 0);
    c.g_object_unref(op);
}

export fn webkit_print_operation_print(op: *Object) void {
    const sit = proxy_view.sitOf(op.priv.view) orelse return c.g_signal_emit(op, print_finished, 0);
    _ = c.g_object_ref(op);
    c.sit_web_view_print(sit, null, op.priv.settings, op.priv.setup, 0, printedAsync, op);
}

export fn webkit_color_chooser_request_get_type() c.GType {
    return colorChooserRequestType();
}

export fn webkit_color_chooser_request_get_rgba(r: *Object, rgba: *c.GdkRGBA) void {
    rgba.* = r.priv.rgba;
}

export fn webkit_color_chooser_request_set_rgba(r: *Object, rgba: *const c.GdkRGBA) void {
    r.priv.rgba = rgba.*;
}

export fn webkit_color_chooser_request_get_element_rectangle(_: *Object, rect: *c.GdkRectangle) void {
    rect.* = std.mem.zeroes(c.GdkRectangle);
}

export fn webkit_color_chooser_request_finish(r: *Object) void {
    c.g_signal_emit(r, chooser_finished, 0);
}

export fn webkit_color_chooser_request_cancel(r: *Object) void {
    c.g_signal_emit(r, chooser_finished, 0);
}

export fn webkit_web_inspector_get_type() c.GType {
    return inspectorType();
}

export fn webkit_web_inspector_get_web_view(_: *Object) ?*c.GObject {
    return null;
}

export fn webkit_web_inspector_get_inspected_uri(i: *Object) [*c]const u8 {
    const v = i.priv.view orelse return null;
    var uri: [*c]const u8 = null;
    c.g_object_get(v, "uri", &uri, @as([*c]const u8, null));
    defer c.g_free(@constCast(uri));
    return c.g_intern_string(uri);
}

export fn webkit_web_inspector_get_can_attach(_: *Object) c.gboolean {
    return 0;
}

export fn webkit_web_inspector_is_attached(_: *Object) c.gboolean {
    return 0;
}

export fn webkit_web_inspector_get_attached_height(_: *Object) c.guint {
    return 0;
}

export fn webkit_web_inspector_show(i: *Object) void {
    const sit = proxy_view.sitOf(i.priv.view) orelse return;
    _ = c.sit_web_view_show_devtools(sit);
}

export fn webkit_web_inspector_close(_: *Object) void {}

export fn webkit_web_inspector_attach(_: *Object) void {}

export fn webkit_web_inspector_detach(_: *Object) void {}
