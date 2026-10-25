const std = @import("std");
const c = @import("c.zig").c;

const BUS = "org.freedesktop.impl.portal.PermissionStore";
const PATH = "/org/freedesktop/impl/portal/PermissionStore";
const IFACE = "org.freedesktop.impl.portal.PermissionStore";

pub const APP_KEY = "fotone-app-id";

pub const Entry = struct {
    table: [*:0]const u8,
    id: [*:0]const u8,
};

pub const CAMERA: Entry = .{ .table = "devices", .id = "camera" };
pub const MICROPHONE: Entry = .{ .table = "devices", .id = "microphone" };
pub const LOCATION: Entry = .{ .table = "location", .id = "location" };
pub const NOTIFICATIONS: Entry = .{ .table = "notifications", .id = "notification" };

pub fn allowedValue(first: []const u8) ?bool {
    if (first.len == 0 or std.mem.eql(u8, first, "ask")) return null;
    if (std.mem.eql(u8, first, "no") or std.mem.eql(u8, first, "NONE")) return false;
    return true;
}

fn bus() ?*c.GDBusConnection {
    return c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null);
}

pub fn lookup(e: Entry, app: [*:0]const u8) ?bool {
    const conn = bus() orelse return null;
    defer c.g_object_unref(conn);
    const reply = c.g_dbus_connection_call_sync(conn, BUS, PATH, IFACE, "Lookup", c.g_variant_new("(ss)", e.table, e.id), c.g_variant_type_checked_("(a{sas}v)"), c.G_DBUS_CALL_FLAGS_NONE, 500, null, null) orelse return null;
    defer c.g_variant_unref(reply);
    const perms = c.g_variant_get_child_value(reply, 0);
    defer c.g_variant_unref(perms);
    var list: ?*c.GVariant = null;
    if (c.g_variant_lookup(perms, app, "@as", &list) == 0) return null;
    defer c.g_variant_unref(list);
    if (c.g_variant_n_children(list) == 0) return null;
    const first = c.g_variant_get_child_value(list, 0);
    defer c.g_variant_unref(first);
    return allowedValue(std.mem.span(c.g_variant_get_string(first, null)));
}

pub fn values(e: Entry, allowed: bool, out: *[2][*:0]const u8, stamp: [*:0]const u8) []const [*:0]const u8 {
    if (std.mem.eql(u8, std.mem.span(e.table), "location")) {
        out.* = .{ if (allowed) "EXACT" else "NONE", stamp };
        return out[0..2];
    }
    out[0] = if (allowed) "yes" else "no";
    return out[0..1];
}

pub fn store(e: Entry, app: [*:0]const u8, allowed: bool) void {
    const conn = bus() orelse return;
    defer c.g_object_unref(conn);
    const stamp = c.g_strdup_printf("%lld", @as(c_longlong, @divTrunc(c.g_get_real_time(), 1000000)));
    defer c.g_free(stamp);
    var buf: [2][*:0]const u8 = undefined;
    const list = values(e, allowed, &buf, stamp);
    const b = c.g_variant_builder_new(c.g_variant_type_checked_("as"));
    defer c.g_variant_builder_unref(b);
    for (list) |v| c.g_variant_builder_add(b, "s", v);
    c.g_dbus_connection_call(conn, BUS, PATH, IFACE, "SetPermission", c.g_variant_new("(sbssas)", e.table, @as(c.gboolean, 1), e.id, app, b), null, c.G_DBUS_CALL_FLAGS_NONE, -1, null, null, null);
}

pub fn appOf(web: ?*c.WebKitWebView) ?[*:0]const u8 {
    const p = c.g_object_get_data(@ptrCast(web orelse return null), APP_KEY) orelse return null;
    return @ptrCast(p);
}

test "stored values decide like the privacy settings do" {
    try std.testing.expectEqual(@as(?bool, true), allowedValue("yes"));
    try std.testing.expectEqual(@as(?bool, true), allowedValue("EXACT"));
    try std.testing.expectEqual(@as(?bool, false), allowedValue("no"));
    try std.testing.expectEqual(@as(?bool, false), allowedValue("NONE"));
    try std.testing.expectEqual(@as(?bool, null), allowedValue("ask"));
    try std.testing.expectEqual(@as(?bool, null), allowedValue(""));
}

test "location grants carry an accuracy and a time" {
    var buf: [2][*:0]const u8 = undefined;
    const loc = values(LOCATION, true, &buf, "17");
    try std.testing.expectEqual(@as(usize, 2), loc.len);
    try std.testing.expectEqualStrings("EXACT", std.mem.span(loc[0]));
    const cam = values(CAMERA, false, &buf, "17");
    try std.testing.expectEqual(@as(usize, 1), cam.len);
    try std.testing.expectEqualStrings("no", std.mem.span(cam[0]));
}
