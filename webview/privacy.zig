const std = @import("std");
const c = @import("c.zig").c;

pub fn clean(out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (n == out.len) break;
        out[n] = if (ch == '"' or ch == '\'' or ch == '\\' or ch < 0x20) ' ' else ch;
        n += 1;
    }
    return out[0..n];
}

pub fn identify() void {
    if (c.g_getenv("PIPEWIRE_PROPS") != null or c.g_getenv("PULSE_PROP") != null) return;
    const app = c.g_application_get_default();
    const id = if (app) |a| c.g_application_get_application_id(a) else null;
    const raw_name = c.g_get_application_name() orelse c.g_get_prgname() orelse return;
    var nb: [128]u8 = undefined;
    var ib: [128]u8 = undefined;
    const name = clean(&nb, std.mem.span(raw_name));
    const ident = clean(&ib, if (id) |i| std.mem.span(i) else std.mem.span(c.g_get_prgname() orelse raw_name));
    const n: c_int = @intCast(name.len);
    const i: c_int = @intCast(ident.len);
    const pw = c.g_strdup_printf("{ application.name = \"%.*s\" application.id = \"%.*s\" }", n, name.ptr, i, ident.ptr);
    defer c.g_free(pw);
    const pulse = c.g_strdup_printf("application.name='%.*s' application.id='%.*s'", n, name.ptr, i, ident.ptr);
    defer c.g_free(pulse);
    _ = c.g_setenv("PIPEWIRE_PROPS", pw, 0);
    _ = c.g_setenv("PULSE_PROP", pulse, 0);
}

test "names are safe inside property lists" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("My  App ", clean(&buf, "My \"App'"));
}
