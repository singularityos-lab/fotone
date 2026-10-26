const std = @import("std");
const c = @import("c.zig").c;
const ui = @import("ui.zig");

const KEY = "fotone-authenticator";

const Cancel = *const fn (?*anyopaque) callconv(.c) void;
const PinDone = *const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) void;
const IndexDone = *const fn (?*anyopaque, c_int) callconv(.c) void;

pub const Status = enum(c_int) {
    multiple_tags = 0,
    no_credentials = 1,
    pin_blocked = 2,
    pin_auth_blocked = 3,
    pin_invalid = 4,
    local_error = 5,
    excluded = 6,
    no_local_credential = 7,
    store_full = 8,
    pin_too_short = 9,
    pin_too_long = 10,
    pin_ok = 11,
    _,
};

pub fn message(status: Status) ?[*:0]const u8 {
    return switch (status) {
        .multiple_tags => "More than one security key is near the reader. Keep only one.",
        .no_credentials => "This security key has no passkey for this site.",
        .pin_blocked => "The PIN of this security key is blocked. Reset the key to use it again.",
        .pin_auth_blocked => "Too many wrong PINs. Remove the security key and insert it again.",
        .pin_invalid => "Wrong PIN.",
        .excluded => "This security key already has a passkey for this site.",
        .store_full => "This security key has no room for another passkey.",
        .pin_too_short => "The PIN is too short.",
        .pin_too_long => "The PIN is too long.",
        else => null,
    };
}

fn tr(s: [*:0]const u8) [*c]const u8 {
    return c.g_dgettext("fotone", s);
}

const Session = struct {
    form: ?*ui.Form = null,
    status: ?*c.GtkWidget = null,
    cancel: Cancel,
    data: ?*anyopaque,
    ended: bool = false,
};

fn widgetOf(web: ?*c.WebKitWebView) ?*c.GtkWidget {
    const w = c.g_object_get_data(@ptrCast(web orelse return null), "fotone-widget") orelse return null;
    return @ptrCast(@alignCast(w));
}

fn sessionOf(web: ?*c.WebKitWebView) ?*Session {
    const s = c.g_object_get_data(@ptrCast(web orelse return null), KEY) orelse return null;
    return @ptrCast(@alignCast(s));
}

fn presenceDone(f: *ui.Form, _: bool) void {
    const s: *Session = @ptrCast(@alignCast(f.data));
    s.form = null;
    s.status = null;
    if (!s.ended) s.cancel(s.data);
}

pub export fn fotone_authenticator_begin(web: ?*c.WebKitWebView, rp: [*:0]const u8, registration: c_int, cancel: Cancel, data: ?*anyopaque) void {
    const w = widgetOf(web) orelse return;
    const s: *Session = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Session))));
    s.* = .{ .cancel = cancel, .data = data };
    c.g_object_set_data_full(@ptrCast(web), KEY, s, c.g_free);
    const title = if (registration != 0) tr("Create a passkey") else tr("Sign in with a passkey");
    const text = c.g_strdup_printf(if (registration != 0) tr("Create a passkey for %s on your security key.") else tr("Use your security key to sign in to %s."), rp);
    defer c.g_free(text);
    const f = ui.Form.new(w, title, text, presenceDone, s);
    const status = c.gtk_label_new(tr("Insert your security key and touch it."));
    c.gtk_label_set_wrap(@ptrCast(status), 1);
    c.gtk_label_set_xalign(@ptrCast(status), 0);
    c.gtk_widget_add_css_class(status, "dim-label");
    c.gtk_box_append(@ptrCast(f.box), status);
    s.form = f;
    s.status = status;
    f.show(null);
}

pub export fn fotone_authenticator_update(web: ?*c.WebKitWebView, status: c_int) void {
    const s = sessionOf(web) orelse return;
    const label = s.status orelse return;
    const text = message(@enumFromInt(status)) orelse return;
    c.gtk_label_set_text(@ptrCast(label), tr(text));
}

pub export fn fotone_authenticator_end(web: ?*c.WebKitWebView, _: c_int) void {
    const s = sessionOf(web) orelse return;
    s.ended = true;
    if (s.form) |f| f.finish(false);
    c.g_object_set_data(@ptrCast(web), KEY, null);
}

const PinCall = struct { done: PinDone, data: ?*anyopaque, fresh: bool, min: u64 };

fn pinDone(f: *ui.Form, ok: bool) void {
    const p: *PinCall = @ptrCast(@alignCast(f.data));
    defer c.g_free(p);
    if (!ok) return p.done(p.data, null);
    const pin = f.text(0);
    if (p.fresh and !validNewPin(std.mem.span(pin), std.mem.span(f.text(1)), p.min)) return p.done(p.data, null);
    p.done(p.data, pin);
}

pub fn validNewPin(pin: []const u8, again: []const u8, min: u64) bool {
    return std.mem.eql(u8, pin, again) and std.unicode.utf8CountCodepoints(pin) catch 0 >= @max(min, 4) and pin.len <= 63;
}

pub export fn fotone_authenticator_pin(web: ?*c.WebKitWebView, retries: u64, fresh: c_int, min: u64, done: PinDone, data: ?*anyopaque) void {
    const w = widgetOf(web) orelse return done(data, null);
    const p: *PinCall = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(PinCall))));
    p.* = .{ .done = done, .data = data, .fresh = fresh != 0, .min = min };
    const text = if (fresh != 0)
        c.g_strdup_printf(tr("Choose a PIN for your security key, at least %u characters long."), @as(c_uint, @intCast(@max(min, 4))))
    else if (retries > 0 and retries < 8)
        c.g_strdup_printf(tr("Enter the PIN of your security key. %u attempts left."), @as(c_uint, @intCast(retries)))
    else
        c.g_strdup(tr("Enter the PIN of your security key."));
    defer c.g_free(text);
    const f = ui.Form.new(w, tr("Security key PIN"), text, pinDone, p);
    f.entry(0, null, true);
    if (fresh != 0) f.entry(1, null, true);
    f.show(c.g_dgettext("gtk40", "_OK"));
}

const SelectCall = struct { done: IndexDone, data: ?*anyopaque, list: *c.GtkWidget };

fn selectDone(f: *ui.Form, ok: bool) void {
    const p: *SelectCall = @ptrCast(@alignCast(f.data));
    defer c.g_free(p);
    const row = c.gtk_list_box_get_selected_row(@ptrCast(p.list));
    p.done(p.data, if (ok and row != null) c.gtk_list_box_row_get_index(row) else -1);
}

pub export fn fotone_authenticator_select(web: ?*c.WebKitWebView, names: [*]const [*:0]const u8, count: usize, done: IndexDone, data: ?*anyopaque) void {
    const w = widgetOf(web) orelse return done(data, -1);
    const list = c.gtk_list_box_new();
    c.gtk_widget_add_css_class(list, "boxed-list");
    for (names[0..count]) |name| {
        const label = c.gtk_label_new(name);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_widget_set_margin_top(label, 8);
        c.gtk_widget_set_margin_bottom(label, 8);
        c.gtk_widget_set_margin_start(label, 12);
        c.gtk_widget_set_margin_end(label, 12);
        c.gtk_list_box_append(@ptrCast(list), label);
    }
    c.gtk_list_box_select_row(@ptrCast(list), c.gtk_list_box_get_row_at_index(@ptrCast(list), 0));
    const p: *SelectCall = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(SelectCall))));
    p.* = .{ .done = done, .data = data, .list = list };
    const f = ui.Form.new(w, tr("Choose an account"), tr("This security key has more than one passkey for this site."), selectDone, p);
    c.gtk_box_append(@ptrCast(f.box), list);
    f.show(tr("_Sign In"));
}

test "statuses map to messages" {
    try std.testing.expect(message(.pin_invalid) != null);
    try std.testing.expect(message(.pin_ok) == null);
    try std.testing.expect(message(@enumFromInt(99)) == null);
}

test "a new pin must match and be long enough" {
    try std.testing.expect(validNewPin("1234", "1234", 0));
    try std.testing.expect(!validNewPin("1234", "1235", 0));
    try std.testing.expect(!validNewPin("123", "123", 0));
    try std.testing.expect(!validNewPin("123456", "123456", 8));
}
