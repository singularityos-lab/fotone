const std = @import("std");
const c = @import("c.zig").c;

pub const ENV = "FOTONE_DEVTOOLS";

var address: ?[*:0]const u8 = null;

pub fn validAddress(s: []const u8) bool {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0) return false;
    const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return false;
    return port != 0;
}

pub fn prepare() void {
    const v = c.g_getenv(ENV) orelse return;
    if (!validAddress(std.mem.span(v))) {
        std.log.warn("fotone devtools: {s} must be host:port", .{ENV});
        return;
    }
    _ = c.g_setenv("WEBKIT_INSPECTOR_HTTP_SERVER", v, 1);
    address = v;
}

pub fn enabled() bool {
    return address != null;
}

pub fn apply(web: *c.WebKitWebView) void {
    if (!enabled()) return;
    const s = c.webkit_web_view_get_settings(web) orelse return;
    c.webkit_settings_set_enable_developer_extras(s, 1);
}

test "devtools need a host and a port" {
    try std.testing.expect(validAddress("127.0.0.1:9222"));
    try std.testing.expect(!validAddress("127.0.0.1"));
    try std.testing.expect(!validAddress(":9222"));
    try std.testing.expect(!validAddress("localhost:0"));
}
