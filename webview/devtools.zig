const std = @import("std");
const c = @import("c.zig").c;

pub const ENV = "FOTONE_DEVTOOLS";
pub const FRONTEND_ENV = "FOTONE_DEVTOOLS_FRONTEND";
const SCHEME = "fotone-devtools";
const HANDLER = "singularityDevtools";
const HOST = @embedFile("devtools/host.js");
const TRANSLATOR = @embedFile("devtools/translator.js");

var address: ?[*:0]u8 = null;
var context: ?*c.WebKitWebContext = null;

pub fn validAddress(s: []const u8) bool {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0) return false;
    const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return false;
    return port != 0;
}

fn freePort() u16 {
    const socket = c.g_socket_new(c.G_SOCKET_FAMILY_IPV4, c.G_SOCKET_TYPE_STREAM, c.G_SOCKET_PROTOCOL_TCP, null) orelse return 0;
    defer c.g_object_unref(socket);
    const loopback = c.g_inet_address_new_loopback(c.G_SOCKET_FAMILY_IPV4);
    defer c.g_object_unref(loopback);
    const any = c.g_inet_socket_address_new(loopback, 0);
    defer c.g_object_unref(any);
    if (c.g_socket_bind(socket, any, 1, null) == 0) return 0;
    const local = c.g_socket_get_local_address(socket, null) orelse return 0;
    defer c.g_object_unref(local);
    const port = c.g_inet_socket_address_get_port(@ptrCast(@alignCast(local)));
    _ = c.g_socket_close(socket, null);
    return port;
}

pub fn prepare() void {
    const v = c.g_getenv(ENV) orelse return;
    const s = std.mem.span(v);
    if (std.mem.eql(u8, s, "1")) {
        const port = freePort();
        if (port == 0) return;
        address = c.g_strdup_printf("127.0.0.1:%u", @as(c_uint, port));
    } else if (validAddress(s)) {
        address = c.g_strdup(v);
    } else {
        std.log.warn("fotone devtools: {s} must be 1 or host:port", .{ENV});
        return;
    }
    _ = c.g_setenv("WEBKIT_INSPECTOR_HTTP_SERVER", address, 1);
}

pub fn enabled() bool {
    return address != null;
}

pub fn apply(web: *c.WebKitWebView) void {
    if (!enabled()) return;
    const s = c.webkit_web_view_get_settings(web) orelse return;
    c.webkit_settings_set_enable_developer_extras(s, 1);
}

fn hasFrontend(dir: [*c]const u8) bool {
    const index = c.g_build_filename(dir, "devtools_app.html", @as([*c]const u8, null));
    defer c.g_free(index);
    return c.g_file_test(index, c.G_FILE_TEST_EXISTS) != 0;
}

pub fn frontendDir() ?[*:0]u8 {
    if (c.g_getenv(FRONTEND_ENV)) |d| return if (hasFrontend(d)) c.g_strdup(d) else null;
    const user = c.g_build_filename(c.g_get_user_data_dir(), "fotone", "devtools", @as([*c]const u8, null));
    if (hasFrontend(user)) return user;
    c.g_free(user);
    var dirs = c.g_get_system_data_dirs();
    while (dirs.* != null) : (dirs += 1) {
        for ([_][*:0]const u8{ "fotone/devtools", "singularity-browser/devtools" }) |sub| {
            const d = c.g_build_filename(dirs.*, sub, @as([*c]const u8, null));
            if (hasFrontend(d)) return d;
            c.g_free(d);
        }
    }
    return null;
}

pub fn available() bool {
    if (!enabled()) return false;
    const d = frontendDir() orelse return false;
    c.g_free(d);
    return true;
}

pub fn mimeFor(path: []const u8) [*:0]const u8 {
    const table = [_]struct { []const u8, [*:0]const u8 }{
        .{ ".js", "text/javascript" },    .{ ".mjs", "text/javascript" },
        .{ ".html", "text/html" },        .{ ".css", "text/css" },
        .{ ".json", "application/json" }, .{ ".map", "application/json" },
        .{ ".svg", "image/svg+xml" },     .{ ".png", "image/png" },
        .{ ".avif", "image/avif" },       .{ ".woff2", "font/woff2" },
        .{ ".wasm", "application/wasm" },
    };
    for (table) |e| if (std.mem.endsWith(u8, path, e[0])) return e[1];
    return "application/octet-stream";
}

fn serve(request: ?*c.WebKitURISchemeRequest, _: c.gpointer) callconv(.c) void {
    const path = c.webkit_uri_scheme_request_get_path(request);
    const root = frontendDir();
    defer c.g_free(root);
    if (root == null or path == null or path[0] == 0 or c.g_strstr_len(path, -1, "..") != null) {
        const err = c.g_error_new_literal(c.g_io_error_quark(), c.G_IO_ERROR_NOT_FOUND, "Not found");
        defer c.g_error_free(err);
        return c.webkit_uri_scheme_request_finish_error(request, err);
    }
    const full = c.g_build_filename(root, path, @as([*c]const u8, null));
    defer c.g_free(full);
    const file = c.g_file_new_for_path(full);
    defer c.g_object_unref(file);
    var err: [*c]c.GError = null;
    const stream = c.g_file_read(file, null, &err) orelse {
        defer c.g_error_free(err);
        return c.webkit_uri_scheme_request_finish_error(request, err);
    };
    defer c.g_object_unref(stream);
    var size: i64 = -1;
    if (c.g_file_query_info(file, c.G_FILE_ATTRIBUTE_STANDARD_SIZE, c.G_FILE_QUERY_INFO_NONE, null, null)) |info| {
        size = c.g_file_info_get_size(info);
        c.g_object_unref(info);
    }
    c.webkit_uri_scheme_request_finish(request, @ptrCast(stream), size, mimeFor(std.mem.span(path)));
}

fn sharedContext() *c.WebKitWebContext {
    if (context) |ctx| return ctx;
    const ctx = c.webkit_web_context_new().?;
    c.webkit_web_context_register_uri_scheme(ctx, SCHEME, serve, null, null);
    const security = c.webkit_web_context_get_security_manager(ctx);
    c.webkit_security_manager_register_uri_scheme_as_secure(security, SCHEME);
    c.webkit_security_manager_register_uri_scheme_as_cors_enabled(security, SCHEME);
    context = ctx;
    return ctx;
}

fn addScript(ucm: *c.WebKitUserContentManager, source: [*c]const u8) void {
    const allow = [_:null]?[*:0]const u8{SCHEME ++ "://*/*"};
    const script = c.webkit_user_script_new(source, c.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, @ptrCast(&allow), null);
    defer c.webkit_user_script_unref(script);
    c.webkit_user_content_manager_add_script(ucm, script);
}

pub fn targets(html: []const u8, uri: []const u8, out: [][]const u8) usize {
    var all: usize = 0;
    var matching: usize = 0;
    var first_match: [16][]const u8 = undefined;
    var rest = html;
    while (std.mem.indexOf(u8, rest, "targeturl\">")) |at| {
        rest = rest[at + 11 ..];
        const end = std.mem.indexOfScalar(u8, rest, '<') orelse break;
        const url = rest[0..end];
        const sock = std.mem.indexOf(u8, rest, "/socket/") orelse break;
        const tail = std.mem.indexOf(u8, rest[sock..], "/WebPage") orelse break;
        const path = rest[sock .. sock + tail + 8];
        if (all < out.len) out[all] = path;
        all += 1;
        if (std.mem.eql(u8, url, uri) and matching < first_match.len) {
            first_match[matching] = path;
            matching += 1;
        }
        rest = rest[sock + tail + 8 ..];
    }
    if (matching == 0) return @min(all, out.len);
    const n = @min(matching, out.len);
    @memcpy(out[0..n], first_match[0..n]);
    return n;
}

const Window = struct {
    window: *c.GtkWindow,
    frontend: *c.WebKitWebView,
    inspected: *c.WebKitWebView,
    marker: [*c]u8,
    session: *c.SoupSession,
    attempts: u32 = 0,
};

fn argString(args: ?*c.JSCValue, i: c.guint) [*c]u8 {
    const v = c.jsc_value_object_get_property_at_index(args, i);
    defer c.g_object_unref(v);
    return c.jsc_value_to_string(v);
}

fn native(_: ?*c.WebKitUserContentManager, value: ?*c.JSCValue, data: c.gpointer) callconv(.c) void {
    const d: *Window = @ptrCast(@alignCast(data));
    const text = c.jsc_value_to_string(value);
    defer c.g_free(text);
    const parsed = c.jsc_value_new_from_json(c.jsc_value_get_context(value), text) orelse return;
    defer c.g_object_unref(parsed);
    const m = c.jsc_value_object_get_property(parsed, "method");
    defer c.g_object_unref(m);
    const method = c.jsc_value_to_string(m);
    defer c.g_free(method);
    const args = c.jsc_value_object_get_property(parsed, "args");
    defer c.g_object_unref(args);
    const name = std.mem.span(method);
    if (std.mem.eql(u8, name, "copyText")) {
        const s = argString(args, 0);
        defer c.g_free(s);
        c.gdk_clipboard_set_text(c.gtk_widget_get_clipboard(@ptrCast(d.window)), s);
    } else if (std.mem.eql(u8, name, "closeWindow")) {
        c.gtk_window_close(d.window);
    } else if (std.mem.eql(u8, name, "bringToFront")) {
        c.gtk_window_present(d.window);
    } else if (std.mem.eql(u8, name, "log")) {
        const s = argString(args, 0);
        defer c.g_free(s);
        std.log.info("devtools: {s}", .{s});
    }
}

fn load(d: *Window, paths: []const []const u8) void {
    const list = c.g_string_new("[");
    defer _ = c.g_string_free(list, 1);
    for (paths, 0..) |p, i| {
        if (i > 0) _ = c.g_string_append_c(list, ',');
        c.g_string_append_printf(list, "\"%.*s\"", @as(c_int, @intCast(p.len)), p.ptr);
    }
    _ = c.g_string_append_c(list, ']');
    const server = c.g_uri_escape_string(address, null, 0);
    defer c.g_free(server);
    const t = c.g_uri_escape_string(list.*.str, null, 0);
    defer c.g_free(t);
    const uri = c.g_strdup_printf(SCHEME ++ "://frontend/devtools_app.html?can_dock=false&server=%s&targets=%s&marker=%s", server, t, d.marker);
    defer c.g_free(uri);
    c.webkit_web_view_load_uri(d.frontend, uri);
}

fn retry(data: c.gpointer) callconv(.c) c.gboolean {
    fetch(@ptrCast(@alignCast(data)));
    return 0;
}

fn listed(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const d: *Window = @ptrCast(@alignCast(data));
    const bytes = c.soup_session_send_and_read_finish(@ptrCast(@alignCast(src)), res, null);
    defer if (bytes) |b| c.g_bytes_unref(b);
    var paths: [16][]const u8 = undefined;
    var n: usize = 0;
    if (bytes) |b| {
        var size: usize = 0;
        const raw = c.g_bytes_get_data(b, &size);
        const page: []const u8 = if (raw) |r| @as([*]const u8, @ptrCast(r))[0..size] else "";
        const uri = c.webkit_web_view_get_uri(d.inspected);
        n = targets(page, if (uri != null) std.mem.span(uri) else "", &paths);
    }
    if (n == 0 and d.attempts < 20) {
        d.attempts += 1;
        _ = c.g_timeout_add(250, retry, d);
        return;
    }
    load(d, paths[0..n]);
}

fn fetch(d: *Window) void {
    const url = c.g_strdup_printf("http://%s/", address);
    defer c.g_free(url);
    const msg = c.soup_message_new("GET", url) orelse return;
    defer c.g_object_unref(msg);
    c.soup_session_send_and_read_async(d.session, msg, c.G_PRIORITY_DEFAULT, null, listed, d);
}

fn destroyed(_: ?*c.GtkWidget, data: c.gpointer) callconv(.c) void {
    const d: *Window = @ptrCast(@alignCast(data));
    while (c.g_source_remove_by_user_data(d) != 0) {}
    c.g_object_unref(d.session);
    c.g_object_unref(d.inspected);
    c.g_free(d.marker);
    c.g_free(d);
}

pub fn open(inspected: *c.WebKitWebView, wrap: *const fn (*c.WebKitWebView) *c.GtkWidget, display: ?*c.WPEDisplay, parent: ?*c.GtkWindow) bool {
    if (!enabled()) return false;
    const root = frontendDir() orelse return false;
    defer c.g_free(root);
    const ucm = c.webkit_user_content_manager_new().?;
    defer c.g_object_unref(ucm);
    addScript(ucm, HOST);
    const compat = c.g_build_filename(root, "devtools_compatibility.js", @as([*c]const u8, null));
    defer c.g_free(compat);
    var text: [*c]u8 = null;
    if (c.g_file_get_contents(compat, &text, null, null) != 0) {
        defer c.g_free(text);
        addScript(ucm, text);
    }
    addScript(ucm, TRANSLATOR);
    _ = c.webkit_user_content_manager_register_script_message_handler(ucm, HANDLER, null);
    const web: *c.WebKitWebView = @ptrCast(@alignCast(c.g_object_new(c.webkit_web_view_get_type(), "web-context", sharedContext(), "user-content-manager", ucm, "display", display, @as([*c]const u8, null))));
    defer c.g_object_unref(web);
    const win: *c.GtkWindow = @ptrCast(@alignCast(c.gtk_window_new()));
    c.gtk_window_set_default_size(win, 1100, 720);
    const title = c.webkit_web_view_get_title(inspected);
    const label = c.g_strdup_printf("%s: %s", c.g_dgettext("fotone", "Developer Tools"), if (title != null and title[0] != 0) title else c.webkit_web_view_get_uri(inspected));
    defer c.g_free(label);
    c.gtk_window_set_title(win, label);
    if (parent) |p| c.gtk_window_set_transient_for(win, p);
    c.gtk_window_set_child(win, wrap(web));
    const d: *Window = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Window))));
    d.* = .{
        .window = win,
        .frontend = web,
        .inspected = @ptrCast(@alignCast(c.g_object_ref(inspected))),
        .marker = c.g_uuid_string_random(),
        .session = c.soup_session_new().?,
    };
    const signal = c.g_strdup_printf("script-message-received::%s", HANDLER);
    defer c.g_free(signal);
    _ = c.g_signal_connect_data(ucm, signal, @ptrCast(&native), d, null, 0);
    _ = c.g_signal_connect_data(win, "destroy", @ptrCast(&destroyed), d, null, 0);
    const mark = c.g_strdup_printf("window.__singularityDevtools = '%s'", d.marker);
    defer c.g_free(mark);
    c.webkit_web_view_evaluate_javascript(inspected, mark, -1, null, null, null, null, null);
    fetch(d);
    c.gtk_window_present(win);
    return true;
}

test "devtools need a host and a port" {
    try std.testing.expect(validAddress("127.0.0.1:9222"));
    try std.testing.expect(!validAddress("127.0.0.1"));
    try std.testing.expect(!validAddress(":9222"));
    try std.testing.expect(!validAddress("localhost:0"));
}

test "a free loopback port is found" {
    try std.testing.expect(freePort() != 0);
}

test "the inspector page lists the page being inspected first" {
    const html = "<div class=\"targeturl\">https://a.org/</div><a href=\"/socket/1/1/WebPage\">x</a>" ++
        "<div class=\"targeturl\">https://b.org/</div><a href=\"/socket/1/2/WebPage\">y</a>";
    var out: [4][]const u8 = undefined;
    const n = targets(html, "https://b.org/", &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("/socket/1/2/WebPage", out[0]);
    try std.testing.expectEqual(@as(usize, 2), targets(html, "https://c.org/", &out));
    try std.testing.expectEqualStrings("text/javascript", std.mem.span(mimeFor("core/sdk.js")));
    try std.testing.expectEqualStrings("font/woff2", std.mem.span(mimeFor("a.woff2")));
}
