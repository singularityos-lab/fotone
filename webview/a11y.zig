const std = @import("std");
const c = @import("c.zig").c;

const KEY = "fotone-a11y-socket";

var parent_iface: ?*c.GtkAccessibleInterface = null;

fn socketOf(o: anytype) ?*c.GtkAccessible {
    return @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(o)), KEY)));
}

fn firstChild(self: ?*c.GtkAccessible) callconv(.c) ?*c.GtkAccessible {
    if (socketOf(self)) |s| return @ptrCast(@alignCast(c.g_object_ref(s)));
    return parent_iface.?.get_first_accessible_child.?(self);
}

fn ifaceInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GtkAccessibleInterface = @ptrCast(@alignCast(iface));
    parent_iface = @ptrCast(@alignCast(c.g_type_interface_peek_parent(iface)));
    const head = i.g_iface;
    i.* = parent_iface.?.*;
    i.g_iface = head;
    i.get_first_accessible_child = firstChild;
}

pub fn implement(t: c.GType) void {
    const info: c.GInterfaceInfo = .{ .interface_init = ifaceInit, .interface_finalize = null, .interface_data = null };
    c.g_type_add_interface_static(t, c.gtk_accessible_get_type(), &info);
}

pub fn split(plug: []const u8) ?[2][]const u8 {
    const at = std.mem.indexOf(u8, plug, ":/") orelse return null;
    if (at == 0) return null;
    return .{ plug[0..at], plug[at + 1 ..] };
}

pub fn plugged(_: ?*c.WPEView, plug: [*c]const u8, data: c.gpointer) callconv(.c) void {
    const w: *c.GtkWidget = @ptrCast(@alignCast(data));
    const parts = split(std.mem.span(plug orelse return)) orelse return;
    const bus = c.g_strndup(parts[0].ptr, parts[0].len);
    defer c.g_free(bus);
    const path = c.g_strndup(parts[1].ptr, parts[1].len);
    defer c.g_free(path);
    var err: [*c]c.GError = null;
    const s = c.gtk_at_spi_socket_new(bus, path, &err) orelse {
        c.g_clear_error(&err);
        return;
    };
    c.gtk_accessible_set_accessible_parent(s, @ptrCast(w), null);
    c.g_object_set_data_full(@ptrCast(w), KEY, s, c.g_object_unref);
}

pub fn clear(w: *c.GtkWidget) void {
    c.g_object_set_data(@ptrCast(w), KEY, null);
}

test "plug ids split into bus name and object path" {
    const p = split(":1.7:/org/a11y/webkit/accessible/root").?;
    try std.testing.expectEqualStrings(":1.7", p[0]);
    try std.testing.expectEqualStrings("/org/a11y/webkit/accessible/root", p[1]);
    try std.testing.expect(split("/only/path") == null);
}
