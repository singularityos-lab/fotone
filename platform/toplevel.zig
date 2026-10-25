const std = @import("std");
const c = @import("c.zig").c;
const g = @import("gobject.zig");

pub const FullscreenFunc = ?*const fn (?*c.WPEToplevel, c.gboolean, c.gpointer) callconv(.c) c.gboolean;

pub const Toplevel = extern struct {
    parent: c.WPEToplevel,
    fullscreen: FullscreenFunc,
    data: c.gpointer,
    destroy: c.GDestroyNotify,
};

const Class = extern struct {
    parent: c.WPEToplevelClass,
};

var once: g.Once = .{};

pub fn getType() c.GType {
    return once.get(make);
}

fn make() c.GType {
    return g.register(c.wpe_toplevel_get_type(), "FotoneToplevel", Class, Toplevel, classInit, null);
}

fn resize(_: [*c]c.WPEToplevel, _: c_int, _: c_int) callconv(.c) c.gboolean {
    return 0;
}

fn of(p: anytype) *Toplevel {
    return @ptrCast(@alignCast(p));
}

fn setFullscreen(toplevel: [*c]c.WPEToplevel, on: c.gboolean) callconv(.c) c.gboolean {
    const t = of(toplevel);
    const f = t.fullscreen orelse return 0;
    return f(toplevel, on, t.data);
}

fn clearFunc(t: *Toplevel) void {
    if (t.destroy) |d| d(t.data);
    t.fullscreen = null;
    t.data = null;
    t.destroy = null;
}

var parent_class: ?*c.GObjectClass = null;

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    clearFunc(of(o));
    parent_class.?.dispose.?(o);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    g.objectClass(klass).dispose = dispose;
    const tc: *c.WPEToplevelClass = @ptrCast(@alignCast(klass));
    tc.resize = resize;
    tc.set_fullscreen = setFullscreen;
}

const Size = struct { w: c_int, h: c_int };

fn resizeView(_: ?*c.WPEToplevel, v: ?*c.WPEView, data: c.gpointer) callconv(.c) c.gboolean {
    const s: *const Size = @ptrCast(@alignCast(data));
    c.wpe_view_resized(v, s.w, s.h);
    return 0;
}

pub export fn fotone_toplevel_get_type() c.GType {
    return getType();
}

pub export fn fotone_toplevel_configure(toplevel: [*c]c.WPEToplevel, width: c_int, height: c_int, scale: f64) void {
    c.wpe_toplevel_resized(toplevel, width, height);
    if (scale > 0 and scale != c.wpe_toplevel_get_scale(toplevel)) c.wpe_toplevel_scale_changed(toplevel, scale);
    var s: Size = .{ .w = width, .h = height };
    c.wpe_toplevel_foreach_view(toplevel, @ptrCast(&resizeView), &s);
}

pub export fn fotone_toplevel_set_fullscreen_func(toplevel: [*c]c.WPEToplevel, func: FullscreenFunc, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const t = of(toplevel);
    clearFunc(t);
    t.fullscreen = func;
    t.data = data;
    t.destroy = destroy;
}

pub export fn fotone_toplevel_set_fullscreened(toplevel: [*c]c.WPEToplevel, on: c.gboolean) void {
    const state = c.wpe_toplevel_get_state(toplevel);
    const next = if (on != 0) state | c.WPE_TOPLEVEL_STATE_FULLSCREEN else state & ~@as(c.WPEToplevelState, c.WPE_TOPLEVEL_STATE_FULLSCREEN);
    if (next != state) c.wpe_toplevel_state_changed(toplevel, next);
}

fn grant(_: ?*c.WPEToplevel, on: c.gboolean, data: c.gpointer) callconv(.c) c.gboolean {
    @as(*c.gboolean, @ptrCast(@alignCast(data))).* = on;
    return 1;
}

test "fullscreen requests reach the host and the state comes back" {
    const d = @import("display.zig").fotone_display_new(null);
    defer c.g_object_unref(d);
    const t: [*c]c.WPEToplevel = @ptrCast(@alignCast(c.g_object_new(getType(), "display", d, @as(?*anyopaque, null))));
    defer c.g_object_unref(t);
    var asked: c.gboolean = 0;
    fotone_toplevel_set_fullscreen_func(t, grant, &asked, null);
    try std.testing.expect(c.wpe_toplevel_fullscreen(t) != 0);
    try std.testing.expectEqual(@as(c.gboolean, 1), asked);
    fotone_toplevel_set_fullscreened(t, 1);
    try std.testing.expect(c.wpe_toplevel_get_state(t) & c.WPE_TOPLEVEL_STATE_FULLSCREEN != 0);
    fotone_toplevel_set_fullscreened(t, 0);
    try std.testing.expect(c.wpe_toplevel_get_state(t) & c.WPE_TOPLEVEL_STATE_FULLSCREEN == 0);
}

test "configure records the size the widget allocates" {
    const d = @import("display.zig").fotone_display_new(null);
    defer c.g_object_unref(d);
    const t: [*c]c.WPEToplevel = @ptrCast(@alignCast(c.g_object_new(getType(), "display", d, @as(?*anyopaque, null))));
    defer c.g_object_unref(t);
    fotone_toplevel_configure(t, 800, 600, 1.25);
    var w: c_int = 0;
    var h: c_int = 0;
    c.wpe_toplevel_get_size(t, &w, &h);
    try std.testing.expectEqual(@as(c_int, 800), w);
    try std.testing.expectEqual(@as(c_int, 600), h);
    try std.testing.expectEqual(@as(f64, 1.25), c.wpe_toplevel_get_scale(t));
}
