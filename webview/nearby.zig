const std = @import("std");
const c = @import("c.zig").c;

const NAME = "dev.sinty.Nearby";
const PATH = "/dev/sinty/Nearby";
const IFACE = "dev.sinty.Nearby1";

fn bus() ?*c.GDBusConnection {
    return c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null);
}

pub const Device = struct { id: [*c]u8, name: [*c]u8 };

pub fn devices(out: []Device) usize {
    const conn = bus() orelse return 0;
    defer c.g_object_unref(conn);
    const reply = c.g_dbus_connection_call_sync(conn, NAME, PATH, IFACE, "ListDevices", null, c.g_variant_type_checked_("(aa{sv})"), c.G_DBUS_CALL_FLAGS_NO_AUTO_START, 250, null, null) orelse return 0;
    defer c.g_variant_unref(reply);
    const list = c.g_variant_get_child_value(reply, 0);
    defer c.g_variant_unref(list);
    var n: usize = 0;
    var i: usize = 0;
    while (i < c.g_variant_n_children(list) and n < out.len) : (i += 1) {
        const d = c.g_variant_get_child_value(list, i);
        defer c.g_variant_unref(d);
        var paired: c.gboolean = 0;
        var reachable: c.gboolean = 0;
        _ = c.g_variant_lookup(d, "paired", "b", &paired);
        _ = c.g_variant_lookup(d, "reachable", "b", &reachable);
        if (paired == 0 or reachable == 0) continue;
        var id: [*c]u8 = null;
        var name: [*c]u8 = null;
        if (c.g_variant_lookup(d, "id", "s", &id) == 0) continue;
        if (c.g_variant_lookup(d, "name", "s", &name) == 0) name = c.g_strdup(id);
        out[n] = .{ .id = id, .name = name };
        n += 1;
    }
    return n;
}

pub fn free(list: []Device) void {
    for (list) |d| {
        c.g_free(d.id);
        c.g_free(d.name);
    }
}

fn shared(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    var err: [*c]c.GError = null;
    const r = c.g_dbus_connection_call_finish(@ptrCast(@alignCast(src)), res, &err);
    if (r) |v| c.g_variant_unref(v) else {
        std.log.warn("fotone nearby: {s}", .{if (err) |e| std.mem.span(e.*.message) else "share failed"});
        c.g_clear_error(&err);
    }
}

pub fn shareUrl(id: [*c]const u8, url: [*c]const u8) void {
    const conn = bus() orelse return;
    defer c.g_object_unref(conn);
    c.g_dbus_connection_call(conn, NAME, PATH, IFACE, "ShareUrl", c.g_variant_new("(ss)", id, url), null, c.G_DBUS_CALL_FLAGS_NONE, -1, null, shared, null);
}
