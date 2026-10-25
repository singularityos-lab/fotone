const std = @import("std");
const c = @import("c.zig").c;
const g = @import("gobject.zig");

pub const FrameFunc = ?*const fn (?*c.WPEView, ?*c.WPEBuffer, c.gpointer) callconv(.c) void;

pub const View = extern struct {
    parent: c.WPEView,
    func: FrameFunc,
    data: c.gpointer,
    destroy: c.GDestroyNotify,
    pending: ?*c.WPEBuffer,
    shown: ?*c.WPEBuffer,
};

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

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const v = of(o);
    clearFunc(v);
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

fn renderBuffer(view: [*c]c.WPEView, buffer: [*c]c.WPEBuffer, _: [*c]const c.WPERectangle, _: c.guint, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const v = of(view);
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

pub export fn fotone_view_frame_presented(view: [*c]c.WPEView) void {
    present(of(view));
}

test "a view without a host frame func presents at once" {
    const d = @import("display.zig").fotone_display_new(null);
    defer c.g_object_unref(d);
    const v: *View = @ptrCast(@alignCast(c.g_object_new(getType(), "display", d, @as(?*anyopaque, null))));
    defer c.g_object_unref(v);
    try std.testing.expect(v.pending == null and v.shown == null);
}
