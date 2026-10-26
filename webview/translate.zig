const std = @import("std");
const c = @import("c.zig").c;
const capabilities = @import("capabilities.zig");

pub const SERVICE = "dev.sinty.TranslateService";
const WORLD = "fotone-translate";
const LIMIT = 1500;

const nodes =
    \\const skip = /^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA|CODE|PRE|SVG|MATH)$/;
    \\const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, { acceptNode(n) {
    \\  const p = n.parentElement;
    \\  if (!p || skip.test(p.tagName.toUpperCase()) || p.isContentEditable || p.closest('[translate="no"], .notranslate')) return NodeFilter.FILTER_REJECT;
    \\  return /\p{L}/u.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
    \\} });
    \\const nodes = [];
    \\for (let n = walker.nextNode(); n && nodes.length < 4000; n = walker.nextNode()) nodes.push(n);
    \\const text = n => n.nodeValue.replace(/\s+/g, ' ').trim();
;

const collect = "(() => {" ++ nodes ++ "return JSON.stringify(nodes.map(text)); })()";

pub fn available() bool {
    const p = capabilities.find(SERVICE) orelse return false;
    p.free();
    return true;
}

pub fn pack(texts: []const []const u8, from: usize, limit: usize) usize {
    var end = from;
    var size: usize = 0;
    while (end < texts.len) : (end += 1) {
        const add = texts[end].len + @intFromBool(end > from);
        if (end > from and size + add > limit) break;
        size += add;
    }
    return end;
}

pub fn split(out: [][]const u8, text: []const u8) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |part| {
        if (n == out.len) return null;
        out[n] = std.mem.trim(u8, part, " ");
        n += 1;
    }
    return n;
}

const Job = struct {
    web: *c.WebKitWebView,
    parsed: std.json.Parsed([][]const u8),
    provider: capabilities.Provider,
    conn: *c.GDBusConnection,
    next: usize = 0,
    end: usize = 0,
    single_until: usize = 0,

    fn texts(j: *Job) [][]const u8 {
        return j.parsed.value;
    }

    fn free(j: *Job) void {
        c.g_object_unref(j.web);
        c.g_object_unref(j.conn);
        j.provider.free();
        j.parsed.deinit();
        std.heap.c_allocator.destroy(j);
    }
};

const Pair = struct { usize, []const u8, []const u8 };

fn apply(j: *Job, pairs: []const Pair) void {
    const a = std.heap.c_allocator;
    const json = std.json.Stringify.valueAlloc(a, pairs, .{}) catch return;
    defer a.free(json);
    const script = std.fmt.allocPrintSentinel(a, "{s}{s}{s}", .{ "(() => {" ++ nodes ++ "for (const [i, from, to] of ", json, ") if (nodes[i] && text(nodes[i]) === from) nodes[i].nodeValue = to; })()" }, 0) catch return;
    defer a.free(script);
    c.webkit_web_view_evaluate_javascript(j.web, script.ptr, -1, WORLD, null, null, null, null);
}

fn translated(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const j: *Job = @ptrCast(@alignCast(data));
    const count = j.end - j.next;
    var err: [*c]c.GError = null;
    const reply = c.g_dbus_connection_call_finish(@ptrCast(@alignCast(src)), res, &err) orelse {
        if (err) |e| std.log.warn("fotone translate: {s}", .{std.mem.span(e.*.message)});
        c.g_clear_error(&err);
        if (count > 1) j.single_until = j.end else j.next = j.end;
        return step(j);
    };
    defer c.g_variant_unref(reply);
    var text: [*c]const u8 = null;
    c.g_variant_get(reply, "(&sss)", &text, @as(?*anyopaque, null), @as(?*anyopaque, null));
    var parts: [LIMIT]Pair = undefined;
    var strs: [LIMIT][]const u8 = undefined;
    const got = split(strs[0..count], std.mem.span(text));
    if (got == null or got.? != count) {
        if (count > 1) {
            j.single_until = j.end;
            return step(j);
        }
    }
    if (count == 1) strs[0] = std.mem.span(text);
    for (0..count) |i| parts[i] = .{ j.next + i, j.texts()[j.next + i], strs[i] };
    apply(j, parts[0..count]);
    j.next = j.end;
    step(j);
}

fn step(j: *Job) void {
    const list = j.texts();
    if (j.next >= list.len) return j.free();
    j.end = if (j.next < j.single_until) j.next + 1 else pack(list, j.next, LIMIT);
    const a = std.heap.c_allocator;
    const joined = std.mem.joinZ(a, "\n", list[j.next..j.end]) catch return j.free();
    defer a.free(joined);
    c.g_dbus_connection_call(j.conn, j.provider.bus, j.provider.path, SERVICE, "Translate", c.g_variant_new("(sss)", joined.ptr, "", ""), c.g_variant_type_checked_("(sss)"), c.G_DBUS_CALL_FLAGS_NONE, 30000, null, translated, j);
}

fn collected(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    const web: *c.WebKitWebView = @ptrCast(@alignCast(src));
    const v = c.webkit_web_view_evaluate_javascript_finish(web, res, null) orelse return;
    defer c.g_object_unref(v);
    const raw = c.jsc_value_to_string(v) orelse return;
    defer c.g_free(raw);
    const a = std.heap.c_allocator;
    const parsed = std.json.parseFromSlice([][]const u8, a, std.mem.span(raw), .{ .allocate = .alloc_always }) catch return;
    const provider = capabilities.find(SERVICE) orelse return parsed.deinit();
    const conn = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse {
        provider.free();
        return parsed.deinit();
    };
    const j = a.create(Job) catch {
        c.g_object_unref(conn);
        provider.free();
        return parsed.deinit();
    };
    j.* = .{ .web = @ptrCast(@alignCast(c.g_object_ref(web))), .parsed = parsed, .provider = provider, .conn = conn };
    step(j);
}

pub fn page(web: *c.WebKitWebView) void {
    c.webkit_web_view_evaluate_javascript(web, collect, -1, WORLD, null, null, collected, null);
}

test "texts pack into chunks under the limit" {
    const t = [_][]const u8{ "aaaa", "bbbb", "cccc", "dddddddddddd" };
    try std.testing.expectEqual(@as(usize, 2), pack(&t, 0, 9));
    try std.testing.expectEqual(@as(usize, 3), pack(&t, 2, 5));
    try std.testing.expectEqual(@as(usize, 4), pack(&t, 3, 5));
    try std.testing.expectEqual(@as(usize, 4), pack(&t, 0, 100));
}

test "a translation splits back into one line per text" {
    var out: [3][]const u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 3), split(&out, "uno\n due \ntre"));
    try std.testing.expectEqualStrings("due", out[1]);
    var small: [2][]const u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), split(&small, "a\nb\nc"));
}
