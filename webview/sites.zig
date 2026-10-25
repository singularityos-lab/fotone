const std = @import("std");
const c = @import("c.zig").c;

const FILE = "site-exceptions.json";
const KEY = "fotone-site";
const BASE_KEY = "fotone-site-base";

const CHROME = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
const FIREFOX = "Mozilla/5.0 (X11; Linux x86_64; rv:144.0) Gecko/20100101 Firefox/144.0";
const SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15";

pub fn agentFor(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "chrome")) return CHROME;
    if (std.mem.eql(u8, name, "firefox")) return FIREFOX;
    if (std.mem.eql(u8, name, "safari")) return SAFARI;
    return name;
}

pub fn matches(domain: []const u8, host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(domain, host)) return true;
    if (host.len <= domain.len + 1) return false;
    const tail = host[host.len - domain.len ..];
    return host[host.len - domain.len - 1] == '.' and std.ascii.eqlIgnoreCase(tail, domain);
}

var tables: [8]std.json.Parsed(std.json.Value) = undefined;
var count: usize = 0;
var loaded = false;

fn loadFile(path: [*:0]const u8) void {
    if (count == tables.len) return;
    var data: [*c]u8 = null;
    var len: usize = 0;
    if (c.g_file_get_contents(path, &data, &len, null) == 0) return;
    defer c.g_free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, data[0..len], .{}) catch return;
    tables[count] = parsed;
    count += 1;
}

fn load() void {
    if (loaded) return;
    loaded = true;
    if (c.g_getenv("FOTONE_SITE_EXCEPTIONS")) |p| return loadFile(p);
    const user = c.g_build_filename(c.g_get_user_config_dir(), "fotone", FILE, @as(?*anyopaque, null));
    defer c.g_free(user);
    loadFile(user);
    var dirs = c.g_get_system_data_dirs();
    while (dirs.* != null) : (dirs += 1) {
        const p = c.g_build_filename(dirs.*, "fotone", FILE, @as(?*anyopaque, null));
        defer c.g_free(p);
        loadFile(p);
    }
}

const Found = struct { site: std.json.ObjectMap, index: usize };

pub fn lookupIn(root: std.json.Value, host: []const u8) ?Found {
    if (root != .object) return null;
    const sites = root.object.get("sites") orelse return null;
    if (sites != .array) return null;
    for (sites.array.items, 0..) |s, i| {
        if (s != .object) continue;
        const domains = s.object.get("domains") orelse continue;
        if (domains != .array) continue;
        for (domains.array.items) |d| if (d == .string and matches(d.string, host)) return .{ .site = s.object, .index = i };
    }
    return null;
}

fn lookup(host: []const u8) ?struct { site: std.json.ObjectMap, id: usize } {
    load();
    for (tables[0..count], 0..) |t, ti| {
        const f = lookupIn(t.value, host) orelse continue;
        return .{ .site = f.site, .id = (ti << 20) + f.index + 1 };
    }
    return null;
}

fn clone(src: *c.WebKitSettings) *c.WebKitSettings {
    const dst: *c.WebKitSettings = @ptrCast(@alignCast(c.g_object_new(c.webkit_settings_get_type(), @as([*c]const u8, null))));
    var n: c.guint = 0;
    const props = c.g_object_class_list_properties(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(src))).g_class)), &n);
    defer c.g_free(@ptrCast(props));
    for (props[0..n]) |p| {
        if ((p.*.flags & c.G_PARAM_WRITABLE) == 0 or (p.*.flags & (c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_DEPRECATED)) != 0) continue;
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, p.*.value_type);
        c.g_object_get_property(@ptrCast(@alignCast(src)), p.*.name, &v);
        c.g_object_set_property(@ptrCast(@alignCast(dst)), p.*.name, &v);
        c.g_value_unset(&v);
    }
    return dst;
}

pub fn apply(settings: *c.WebKitSettings, site: std.json.ObjectMap) void {
    if (site.get("user-agent")) |ua| if (ua == .string) {
        const z = c.g_strndup(ua.string.ptr, ua.string.len);
        defer c.g_free(z);
        const agent = agentFor(std.mem.span(z));
        const az = c.g_strndup(agent.ptr, agent.len);
        defer c.g_free(az);
        c.webkit_settings_set_user_agent(settings, az);
    };
    const values = site.get("settings") orelse return;
    if (values != .object) return;
    var it = values.object.iterator();
    while (it.next()) |e| {
        const name = c.g_strndup(e.key_ptr.ptr, e.key_ptr.len);
        defer c.g_free(name);
        const spec = c.g_object_class_find_property(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(settings))).g_class)), name) orelse continue;
        switch (e.value_ptr.*) {
            .bool => |b| if (spec.*.value_type == c.G_TYPE_BOOLEAN) c.g_object_set(settings, name, @as(c.gboolean, @intFromBool(b)), @as([*c]const u8, null)),
            .integer => |i| if (spec.*.value_type == c.G_TYPE_UINT) c.g_object_set(settings, name, @as(c.guint, @intCast(@max(i, 0))), @as([*c]const u8, null)),
            .string => |s| if (spec.*.value_type == c.G_TYPE_STRING) {
                const z = c.g_strndup(s.ptr, s.len);
                defer c.g_free(z);
                c.g_object_set(settings, name, z, @as([*c]const u8, null));
            },
            else => {},
        }
    }
}

fn hostOf(uri: [*:0]const u8, buf: []u8) ?[]const u8 {
    const u = c.g_uri_parse(uri, c.G_URI_FLAGS_NONE, null) orelse return null;
    defer c.g_uri_unref(u);
    const h = std.mem.span(c.g_uri_get_host(u) orelse return null);
    if (h.len > buf.len) return null;
    @memcpy(buf[0..h.len], h);
    return buf[0..h.len];
}

fn decide(web: ?*c.WebKitWebView, decision: ?*c.WebKitPolicyDecision, kind: c.WebKitPolicyDecisionType, _: c.gpointer) callconv(.c) c.gboolean {
    if (kind != c.WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) return 0;
    const v = web orelse return 0;
    const action = c.webkit_navigation_policy_decision_get_navigation_action(@ptrCast(decision)) orelse return 0;
    const request = c.webkit_navigation_action_get_request(action) orelse return 0;
    var buf: [256]u8 = undefined;
    const host = hostOf(c.webkit_uri_request_get_uri(request) orelse return 0, &buf) orelse return 0;
    const found = lookup(host);
    const want: usize = if (found) |f| f.id else 0;
    const have = @intFromPtr(c.g_object_get_data(@ptrCast(v), KEY));
    if (want == have) return 0;
    const current = c.webkit_web_view_get_settings(v) orelse return 0;
    if (c.g_object_get_data(@ptrCast(v), BASE_KEY) == null) c.g_object_set_data_full(@ptrCast(v), BASE_KEY, clone(current), c.g_object_unref);
    const base: *c.WebKitSettings = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(v), BASE_KEY)));
    const next = clone(base);
    defer c.g_object_unref(next);
    if (found) |f| apply(next, f.site);
    c.webkit_web_view_set_settings(v, next);
    c.g_object_set_data(@ptrCast(v), KEY, @ptrFromInt(want));
    if (c.webkit_navigation_action_is_redirect(action) != 0) return 0;
    _ = c.g_object_ref(request);
    defer c.g_object_unref(request);
    c.webkit_policy_decision_ignore(decision);
    c.webkit_web_view_load_request(v, request);
    return 1;
}

pub fn hook(web: *c.WebKitWebView) void {
    _ = c.g_signal_connect_data(web, "decide-policy", @ptrCast(&decide), null, null, 0);
}

test "domains cover their subdomains only" {
    try std.testing.expect(matches("spotify.com", "open.spotify.com"));
    try std.testing.expect(matches("spotify.com", "Spotify.com"));
    try std.testing.expect(!matches("spotify.com", "notspotify.com"));
    try std.testing.expect(!matches("open.spotify.com", "spotify.com"));
}

test "a site entry sets the agent and typed engine settings" {
    const json =
        \\{"sites":[{"domains":["teams.microsoft.com"],"user-agent":"chrome","settings":{"enable-webgl":false,"default-font-size":18,"bogus":1}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(lookupIn(parsed.value, "example.org") == null);
    const site = lookupIn(parsed.value, "teams.microsoft.com").?.site;
    const s: *c.WebKitSettings = @ptrCast(@alignCast(c.g_object_new(c.webkit_settings_get_type(), @as([*c]const u8, null))));
    defer c.g_object_unref(s);
    apply(s, site);
    try std.testing.expectEqualStrings(CHROME, std.mem.span(c.webkit_settings_get_user_agent(s)));
    try std.testing.expectEqual(@as(c.gboolean, 0), c.webkit_settings_get_enable_webgl(s));
    try std.testing.expectEqual(@as(c.guint, 18), c.webkit_settings_get_default_font_size(s));
    const copy = clone(s);
    defer c.g_object_unref(copy);
    try std.testing.expectEqual(@as(c.guint, 18), c.webkit_settings_get_default_font_size(copy));
    try std.testing.expectEqualStrings(CHROME, std.mem.span(c.webkit_settings_get_user_agent(copy)));
}
