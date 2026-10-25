const std = @import("std");
const c = @import("c.zig").c;

pub const PREFIX = "dev.sinty.webapp.";

pub fn slug(out: []u8, host: []const u8) []const u8 {
    var n: usize = 0;
    for (host) |ch| {
        if (n == out.len) break;
        out[n] = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '_';
        n += 1;
    }
    return out[0..n];
}

pub fn appId(uri: [*:0]const u8) ?[*:0]u8 {
    const parsed = c.g_uri_parse(uri, c.G_URI_FLAGS_NONE, null) orelse return null;
    defer c.g_uri_unref(parsed);
    const host = c.g_uri_get_host(parsed) orelse return null;
    var buf: [128]u8 = undefined;
    const s = slug(&buf, std.mem.span(host));
    return c.g_strdup_printf("%s%.*s", PREFIX, @as(c_int, @intCast(s.len)), s.ptr);
}

pub fn desktopEntry(id: [*:0]const u8, name: [*:0]const u8, uri: [*:0]const u8) [*:0]u8 {
    return c.g_strdup_printf(
        "[Desktop Entry]\nType=Application\nName=%s\nExec=fotone-viewer --app %s %s\nIcon=%s\nStartupWMClass=%s\nCategories=Network;WebApp;\nX-Fotone-Uri=%s\n",
        name,
        id,
        uri,
        id,
        id,
        uri,
    );
}

fn dataPath(parts: []const [*:0]const u8) [*:0]u8 {
    var path: [*:0]u8 = c.g_strdup(c.g_get_user_data_dir());
    for (parts) |p| {
        const next = c.g_build_filename(path, p, @as([*c]const u8, null));
        c.g_free(path);
        path = next;
    }
    return path;
}

pub fn install(id: [*:0]const u8, name: [*:0]const u8, uri: [*:0]const u8, icon: ?*c.GdkTexture, err: [*c][*c]c.GError) ?[*:0]u8 {
    const apps = dataPath(&.{"applications"});
    defer c.g_free(apps);
    _ = c.g_mkdir_with_parents(apps, 0o755);
    const file = c.g_strdup_printf("%s/%s.desktop", apps, id);
    const entry = desktopEntry(id, name, uri);
    defer c.g_free(entry);
    if (c.g_file_set_contents(file, entry, -1, err) == 0) {
        c.g_free(file);
        return null;
    }
    if (icon) |t| {
        const dir = dataPath(&.{ "icons", "hicolor", "256x256", "apps" });
        defer c.g_free(dir);
        _ = c.g_mkdir_with_parents(dir, 0o755);
        const png = c.g_strdup_printf("%s/%s.png", dir, id);
        defer c.g_free(png);
        _ = c.gdk_texture_save_to_png(t, png);
    }
    return file;
}

pub fn session(id: [*:0]const u8) ?*c.WebKitNetworkSession {
    const data = dataPath(&.{ "fotone", "apps", id });
    defer c.g_free(data);
    const cache = c.g_build_filename(c.g_get_user_cache_dir(), "fotone", "apps", id, @as([*c]const u8, null));
    defer c.g_free(cache);
    return c.webkit_network_session_new(data, cache);
}

pub fn pageIcon(web: *c.WebKitWebView) ?*c.GdkTexture {
    const list = c.webkit_web_view_get_page_icons(web) orelse return null;
    var best: ?*c.WebKitImage = null;
    var size: c_int = 0;
    var i: c.guint = 0;
    while (i < c.webkit_image_list_get_length(list)) : (i += 1) {
        const img = c.webkit_image_list_get(list, i);
        if (c.webkit_image_get_width(img) > size) {
            size = c.webkit_image_get_width(img);
            best = img;
        }
    }
    const img = best orelse return null;
    const bytes = c.webkit_image_as_bytes(img) orelse return null;
    defer c.g_bytes_unref(bytes);
    return c.gdk_memory_texture_new(c.webkit_image_get_width(img), c.webkit_image_get_height(img), c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, c.webkit_image_get_stride(img));
}

test "hosts become stable application ids" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("app_example_org", slug(&buf, "App.Example.org"));
    const id = appId("https://mail.example.org/inbox").?;
    defer c.g_free(id);
    try std.testing.expectEqualStrings("dev.sinty.webapp.mail_example_org", std.mem.span(id));
}

test "desktop entries launch the viewer in app mode" {
    const e = desktopEntry("dev.sinty.webapp.x", "X", "https://x.org/");
    defer c.g_free(e);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(e), "Exec=fotone-viewer --app dev.sinty.webapp.x https://x.org/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(e), "StartupWMClass=dev.sinty.webapp.x\n") != null);
}
