const std = @import("std");
const c = @import("c.zig").c;

var schema: c.SecretSchema = undefined;
var schema_ready = false;

fn passwordSchema() *const c.SecretSchema {
    if (!schema_ready) {
        schema = std.mem.zeroes(c.SecretSchema);
        schema.name = "dev.sinty.fotone.Password";
        schema.flags = c.SECRET_SCHEMA_NONE;
        schema.attributes[0] = .{ .name = "host", .type = c.SECRET_SCHEMA_ATTRIBUTE_STRING };
        schema.attributes[1] = .{ .name = "username", .type = c.SECRET_SCHEMA_ATTRIBUTE_STRING };
        schema_ready = true;
    }
    return &schema;
}

const FILL =
    \\var pw = document.querySelector('input[type=password]');
    \\if (!pw || pw.value) return false;
    \\var scope = pw.form || document;
    \\var fields = scope.querySelectorAll('input[type=text], input[type=email], input:not([type])');
    \\var user = null;
    \\for (var i = 0; i < fields.length; i++) if (fields[i].compareDocumentPosition(pw) & 4) user = fields[i];
    \\function set(e, v) { e.value = v; e.dispatchEvent(new Event('input', { bubbles: true })); e.dispatchEvent(new Event('change', { bubbles: true })); }
    \\if (user && !user.value) set(user, u);
    \\set(pw, p);
    \\return true;
;

const PROBE = "return !!document.querySelector('input[type=password]');";

pub fn hostOf(uri: [*c]const u8) ?[*:0]u8 {
    if (uri == null) return null;
    const parsed = c.g_uri_parse(uri, c.G_URI_FLAGS_NONE, null) orelse return null;
    defer c.g_uri_unref(parsed);
    const scheme = c.g_uri_get_scheme(parsed);
    const host = c.g_uri_get_host(parsed) orelse return null;
    const secure = c.g_strcmp0(scheme, "https") == 0 or (c.g_strcmp0(scheme, "http") == 0 and (c.g_strcmp0(host, "localhost") == 0 or c.g_strcmp0(host, "127.0.0.1") == 0));
    if (!secure) return null;
    return c.g_strdup(host);
}

pub fn isPasswordName(name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n = @min(name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], name[0..n]);
    for ([_][]const u8{ "pass", "pwd", "pin" }) |k| if (std.mem.indexOf(u8, lower, k) != null) return true;
    return false;
}

pub fn pick(names: []const []const u8, values: []const []const u8) ?struct { user: usize, password: usize } {
    var pw: ?usize = null;
    for (names, 0..) |n, i| if (isPasswordName(n) and values[i].len > 0) {
        pw = i;
        break;
    };
    const p = pw orelse return null;
    var user: ?usize = null;
    for (values, 0..) |v, i| {
        if (i == p or v.len == 0 or isPasswordName(names[i])) continue;
        if (i > p and user != null) break;
        user = i;
        if (i > p) break;
    }
    return .{ .user = user orelse return null, .password = p };
}

const Save = struct {
    host: [*c]u8,
    user: [*c]u8,
    password: [*c]u8,
    parent: ?*c.GtkWindow,

    fn free(s: *Save) void {
        if (s.parent) |p| c.g_object_unref(p);
        c.g_free(s.host);
        c.g_free(s.user);
        if (s.password != null) {
            @memset(std.mem.span(s.password), 0);
            c.g_free(s.password);
        }
        c.g_free(s);
    }
};

fn stored(_: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    var err: [*c]c.GError = null;
    if (c.secret_password_store_finish(res, &err) == 0) {
        std.log.warn("fotone passwords: {s}", .{if (err) |e| std.mem.span(e.*.message) else "cannot store"});
        c.g_clear_error(&err);
    }
}

fn saveChosen(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const s: *Save = @ptrCast(@alignCast(data));
    defer s.free();
    if (c.gtk_alert_dialog_choose_finish(@ptrCast(@alignCast(src)), res, null) != 1) return;
    const label = c.g_strdup_printf("%s (%s)", s.host, s.user);
    defer c.g_free(label);
    c.secret_password_store(passwordSchema(), c.SECRET_COLLECTION_DEFAULT, label, s.password, null, stored, null, "host", s.host, "username", s.user, @as([*c]const u8, null));
}

fn known(_: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const s: *Save = @ptrCast(@alignCast(data));
    const existing = c.secret_password_lookup_finish(res, null);
    defer if (existing != null) c.secret_password_free(existing);
    if (existing != null and c.g_strcmp0(existing, s.password) == 0) return s.free();
    const message = c.g_strdup_printf(c.g_dgettext("fotone", "Save the password for %s on %s?"), s.user, s.host);
    defer c.g_free(message);
    const d = c.gtk_alert_dialog_new("%s", message);
    defer c.g_object_unref(d);
    const labels = [_:null]?[*:0]const u8{ c.g_dgettext("fotone", "_Not Now"), c.g_dgettext("fotone", "_Save") };
    c.gtk_alert_dialog_set_buttons(d, @ptrCast(&labels));
    c.gtk_alert_dialog_set_cancel_button(d, 0);
    c.gtk_alert_dialog_set_default_button(d, 1);
    c.gtk_alert_dialog_choose(d, s.parent, null, saveChosen, s);
}

pub fn submitted(web: *c.WebKitWebView, req: *c.WebKitFormSubmissionRequest, parent: ?*c.GtkWindow) void {
    const host = hostOf(c.webkit_web_view_get_uri(web)) orelse return;
    var names: [*c]c.GPtrArray = null;
    var values: [*c]c.GPtrArray = null;
    if (c.webkit_form_submission_request_list_text_fields(req, &names, &values) == 0 or names == null) {
        c.g_free(host);
        return;
    }
    var nb: [64][]const u8 = undefined;
    var vb: [64][]const u8 = undefined;
    const n = @min(names.*.len, nb.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        nb[i] = std.mem.span(@as([*:0]const u8, @ptrCast(names.*.pdata[i])));
        vb[i] = std.mem.span(@as([*:0]const u8, @ptrCast(values.*.pdata[i])));
    }
    const choice = pick(nb[0..n], vb[0..n]) orelse {
        c.g_free(host);
        return;
    };
    const s: *Save = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Save))));
    s.* = .{
        .host = host,
        .user = c.g_strndup(vb[choice.user].ptr, vb[choice.user].len),
        .password = c.g_strndup(vb[choice.password].ptr, vb[choice.password].len),
        .parent = if (parent) |p| @ptrCast(@alignCast(c.g_object_ref(p))) else null,
    };
    c.secret_password_lookup(passwordSchema(), null, known, s, "host", s.host, "username", s.user, @as([*c]const u8, null));
}

const Fill = struct {
    web: *c.WebKitWebView,
    host: [*c]u8,
    user: [*c]u8 = null,

    fn free(f: *Fill) void {
        c.g_object_unref(f.web);
        c.g_free(f.host);
        c.g_free(f.user);
        c.g_free(f);
    }
};

fn filled(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    if (c.webkit_web_view_evaluate_javascript_finish(@ptrCast(@alignCast(src)), res, null)) |v| c.g_object_unref(v);
}

fn gotPassword(_: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const f: *Fill = @ptrCast(@alignCast(data));
    defer f.free();
    const password = c.secret_password_lookup_finish(res, null) orelse return;
    defer c.secret_password_free(password);
    var b: c.GVariantBuilder = undefined;
    c.g_variant_builder_init(&b, c.g_variant_type_checked_("a{sv}"));
    c.g_variant_builder_add(&b, "{sv}", "u", c.g_variant_new_string(f.user));
    c.g_variant_builder_add(&b, "{sv}", "p", c.g_variant_new_string(password));
    c.webkit_web_view_call_async_javascript_function(f.web, FILL, -1, c.g_variant_builder_end(&b), "fotone-passwords", null, null, filled, null);
}

fn found(_: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const f: *Fill = @ptrCast(@alignCast(data));
    const items = c.secret_password_search_finish(res, null) orelse return f.free();
    defer c.g_list_free_full(items, c.g_object_unref);
    const attrs = c.secret_retrievable_get_attributes(@ptrCast(@alignCast(items.*.data)));
    defer c.g_hash_table_unref(attrs);
    const user = c.g_hash_table_lookup(attrs, "username") orelse return f.free();
    f.user = c.g_strdup(@ptrCast(user));
    c.secret_password_lookup(passwordSchema(), null, gotPassword, f, "host", f.host, "username", f.user, @as([*c]const u8, null));
}

fn probed(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const f: *Fill = @ptrCast(@alignCast(data));
    const v = c.webkit_web_view_evaluate_javascript_finish(@ptrCast(@alignCast(src)), res, null) orelse return f.free();
    defer c.g_object_unref(v);
    if (c.jsc_value_to_boolean(v) == 0) return f.free();
    c.secret_password_search(passwordSchema(), c.SECRET_SEARCH_NONE, null, found, f, "host", f.host, @as([*c]const u8, null));
}

pub fn fill(web: *c.WebKitWebView) void {
    const host = hostOf(c.webkit_web_view_get_uri(web)) orelse return;
    const f: *Fill = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Fill))));
    f.* = .{ .web = @ptrCast(@alignCast(c.g_object_ref(web))), .host = host };
    c.webkit_web_view_call_async_javascript_function(web, PROBE, -1, null, "fotone-passwords", null, null, probed, f);
}

test "only secure origins get passwords" {
    const h = hostOf("https://login.example.org/a").?;
    defer c.g_free(h);
    try std.testing.expectEqualStrings("login.example.org", std.mem.span(h));
    try std.testing.expect(hostOf("http://example.org/") == null);
    const l = hostOf("http://localhost:8080/").?;
    c.g_free(l);
}

test "the password and the user are found among the fields" {
    const r = pick(&.{ "email", "password", "remember" }, &.{ "me@example.org", "s3cret", "on" }).?;
    try std.testing.expectEqual(@as(usize, 0), r.user);
    try std.testing.expectEqual(@as(usize, 1), r.password);
    try std.testing.expect(pick(&.{ "q", "lang" }, &.{ "zig", "it" }) == null);
    try std.testing.expect(pick(&.{ "user", "pwd" }, &.{ "", "x" }) == null);
}
