const std = @import("std");
const c = @import("c.zig").c;
const g = @import("gobject.zig");

pub const FrameFunc = ?*const fn (?*c.WPEView, ?*c.WPEBuffer, c.gpointer) callconv(.c) void;
pub const AccessibleFunc = ?*const fn (?*c.WPEView, [*c]const u8, c.gpointer) callconv(.c) void;

pub const View = extern struct {
    parent: c.WPEView,
    func: FrameFunc,
    data: c.gpointer,
    destroy: c.GDestroyNotify,
    pending: ?*c.WPEBuffer,
    shown: ?*c.WPEBuffer,
    accessible: ?*Accessible,
    plug: [*c]u8,
    a11y_func: AccessibleFunc,
    a11y_data: c.gpointer,
    a11y_destroy: c.GDestroyNotify,
    damage: [max_damage]c.WPERectangle,
    n_damage: c.guint,
};

const max_damage = 16;

const Accessible = extern struct {
    parent: c.GObject,
    view: ?*View,
};

const AccessibleClass = extern struct {
    parent: c.GObjectClass,
};

var accessible_once: g.Once = .{};

fn accessibleType() c.GType {
    return accessible_once.get(makeAccessible);
}

fn makeAccessible() c.GType {
    const t = g.register(c.g_object_get_type(), "FotoneViewAccessible", AccessibleClass, Accessible, null, null);
    const info: c.GInterfaceInfo = .{ .interface_init = accessibleIfaceInit, .interface_finalize = null, .interface_data = null };
    c.g_type_add_interface_static(t, c.wpe_view_accessible_get_type(), &info);
    return t;
}

fn bind(a: ?*c.WPEViewAccessible, plug: [*c]const u8) callconv(.c) void {
    const acc: *Accessible = @ptrCast(@alignCast(a));
    const v = acc.view orelse return;
    c.g_free(v.plug);
    v.plug = c.g_strdup(plug);
    if (v.a11y_func) |f| f(&v.parent, v.plug, v.a11y_data);
}

fn accessibleIfaceInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.WPEViewAccessibleInterface = @ptrCast(@alignCast(iface));
    i.bind = bind;
}

fn getAccessible(view: [*c]c.WPEView) callconv(.c) ?*c.WPEViewAccessible {
    const v = of(view);
    if (v.accessible == null) {
        const a: *Accessible = @ptrCast(@alignCast(c.g_object_new(accessibleType(), @as([*c]const u8, null))));
        a.view = v;
        v.accessible = a;
    }
    return @ptrCast(v.accessible);
}

const Class = extern struct {
    parent: c.WPEViewClass,
};

var parent_class: ?*c.GObjectClass = null;
var once: g.Once = .{};

pub fn getType() c.GType {
    return once.get(make);
}

fn make() c.GType {
    return g.register(c.wpe_view_get_type(), "FotoneView", Class, View, classInit, null);
}

fn of(p: anytype) *View {
    return @ptrCast(@alignCast(p));
}

fn toplevelChanged(v: ?*c.WPEView, _: ?*c.GParamSpec, _: c.gpointer) callconv(.c) void {
    const t = c.wpe_view_get_toplevel(v) orelse {
        c.wpe_view_unmap(v);
        return;
    };
    var w: c_int = 0;
    var h: c_int = 0;
    c.wpe_toplevel_get_size(t, &w, &h);
    if (w > 0 and h > 0) c.wpe_view_resized(v, w, h);
    c.wpe_view_map(v);
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    parent_class.?.constructed.?(o);
    _ = c.g_signal_connect_data(o, "notify::toplevel", @ptrCast(&toplevelChanged), null, null, 0);
}

fn clearFunc(v: *View) void {
    if (v.destroy) |d| d(v.data);
    v.func = null;
    v.data = null;
    v.destroy = null;
}

fn clearAccessibleFunc(v: *View) void {
    if (v.a11y_destroy) |d| d(v.a11y_data);
    v.a11y_func = null;
    v.a11y_data = null;
    v.a11y_destroy = null;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const v = of(o);
    clearFunc(v);
    clearAccessibleFunc(v);
    if (v.accessible) |a| {
        a.view = null;
        c.g_object_unref(a);
        v.accessible = null;
    }
    c.g_free(v.plug);
    v.plug = null;
    g.unrefPtr(&v.pending);
    g.unrefPtr(&v.shown);
    parent_class.?.dispose.?(o);
}

fn present(v: *View) void {
    const b = v.pending orelse return;
    v.pending = null;
    if (v.shown) |old| {
        c.wpe_view_buffer_released(&v.parent, old);
        c.g_object_unref(old);
    }
    v.shown = b;
    c.wpe_view_buffer_rendered(&v.parent, b);
}

fn renderBuffer(view: [*c]c.WPEView, buffer: [*c]c.WPEBuffer, rects: [*c]const c.WPERectangle, n: c.guint, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const v = of(view);
    v.n_damage = if (n > max_damage or rects == null) 0 else n;
    if (v.n_damage > 0) @memcpy(v.damage[0..v.n_damage], rects[0..v.n_damage]);
    g.unrefPtr(&v.pending);
    v.pending = @ptrCast(@alignCast(c.g_object_ref(buffer)));
    if (v.func) |f| f(view, buffer, v.data) else present(v);
    return 1;
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const oc = g.objectClass(klass);
    oc.constructed = constructed;
    oc.dispose = dispose;
    const vc: *c.WPEViewClass = @ptrCast(@alignCast(klass));
    vc.render_buffer = renderBuffer;
    vc.get_accessible = getAccessible;
}

pub export fn fotone_view_get_type() c.GType {
    return getType();
}

pub export fn fotone_view_set_frame_func(view: [*c]c.WPEView, func: FrameFunc, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const v = of(view);
    clearFunc(v);
    v.func = func;
    v.data = data;
    v.destroy = destroy;
}

pub export fn fotone_view_get_damage(view: [*c]c.WPEView, n: [*c]c.guint) [*c]const c.WPERectangle {
    const v = of(view);
    n.* = v.n_damage;
    return &v.damage;
}

pub export fn fotone_view_frame_presented(view: [*c]c.WPEView) void {
    present(of(view));
}

pub export fn fotone_view_set_accessible_func(view: [*c]c.WPEView, func: AccessibleFunc, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const v = of(view);
    clearAccessibleFunc(v);
    v.a11y_func = func;
    v.a11y_data = data;
    v.a11y_destroy = destroy;
    if (v.plug != null) if (func) |f| f(view, v.plug, data);
}

pub export fn fotone_view_get_accessible_plug(view: [*c]c.WPEView) [*c]const u8 {
    return of(view).plug;
}

test "a view without a host frame func presents at once" {
    const d = @import("display.zig").fotone_display_new(null);
    defer c.g_object_unref(d);
    const v: *View = @ptrCast(@alignCast(c.g_object_new(getType(), "display", d, @as(?*anyopaque, null))));
    defer c.g_object_unref(v);
    try std.testing.expect(v.pending == null and v.shown == null);
}

test "the engine binds its accessibility tree through the view" {
    const d = @import("display.zig").fotone_display_new(null);
    defer c.g_object_unref(d);
    const v: *View = @ptrCast(@alignCast(c.g_object_new(getType(), "display", d, @as(?*anyopaque, null))));
    defer c.g_object_unref(v);
    const a = c.wpe_view_get_accessible(&v.parent);
    try std.testing.expect(a != null);
    try std.testing.expect(a == c.wpe_view_get_accessible(&v.parent));
    c.wpe_view_accessible_bind(a, ":1.42:/org/a11y/atspi/accessible/1");
    try std.testing.expectEqualStrings(":1.42:/org/a11y/atspi/accessible/1", std.mem.span(fotone_view_get_accessible_plug(&v.parent)));
}
