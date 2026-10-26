const std = @import("std");
const c = @import("c.zig").c;

const Json = std.json.Value;
const gpa = std.heap.c_allocator;

pub const Result = struct {
    json: []u8,
    converted: usize,
    skipped: usize,

    pub fn deinit(r: Result) void {
        gpa.free(r.json);
    }
};

const Kind = enum(u8) { headers, redirect, upgrade, block, allow_all, allow };

const Rule = struct {
    priority: i64,
    kind: Kind,
    id: i64,
    text: []u8,
};

pub const Out = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn raw(o: *Out, s: []const u8) !void {
        try o.buf.appendSlice(gpa, s);
    }

    pub fn str(o: *Out, s: []const u8) !void {
        try o.raw("\"");
        for (s) |ch| switch (ch) {
            '"' => try o.raw("\\\""),
            '\\' => try o.raw("\\\\"),
            '\n' => try o.raw("\\n"),
            0...9, 11...0x1f => {
                var tmp: [6]u8 = undefined;
                try o.raw(std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{ch}) catch unreachable);
            },
            else => try o.buf.append(gpa, ch),
        };
        try o.raw("\"");
    }

    pub fn key(o: *Out, k: []const u8) !void {
        if (o.buf.items.len > 0 and o.buf.items[o.buf.items.len - 1] != '{' and o.buf.items[o.buf.items.len - 1] != '[') try o.raw(",");
        try o.str(k);
        try o.raw(":");
    }

    pub fn item(o: *Out) !void {
        if (o.buf.items.len > 0 and o.buf.items[o.buf.items.len - 1] != '[') try o.raw(",");
    }
};

const types = [_]struct { []const u8, []const []const u8 }{
    .{ "main_frame", &.{"top-document"} },
    .{ "sub_frame", &.{"child-document"} },
    .{ "stylesheet", &.{"style-sheet"} },
    .{ "script", &.{"script"} },
    .{ "image", &.{"image"} },
    .{ "font", &.{"font"} },
    .{ "xmlhttprequest", &.{ "fetch", "raw" } },
    .{ "websocket", &.{"websocket"} },
    .{ "object", &.{"other"} },
    .{ "media", &.{"other"} },
    .{ "ping", &.{"other"} },
    .{ "csp_report", &.{"other"} },
    .{ "webtransport", &.{"other"} },
    .{ "webbundle", &.{"other"} },
    .{ "other", &.{"other"} },
};

const all_engine_types = [_][]const u8{ "top-document", "child-document", "style-sheet", "script", "image", "font", "fetch", "raw", "websocket", "other", "svg-document" };

fn engineTypes(name: []const u8) ?[]const []const u8 {
    for (types) |t| if (std.mem.eql(u8, t[0], name)) return t[1];
    return null;
}

pub fn filterRegex(o: *Out, filter: []const u8) !void {
    var s = filter;
    if (s.len == 0) return o.raw(".*");
    if (std.mem.startsWith(u8, s, "||")) {
        try o.raw("^[a-z][a-z0-9+.-]*://([^/?#]*\\\\.)?");
        s = s[2..];
    } else if (s[0] == '|') {
        try o.raw("^");
        s = s[1..];
    }
    var end = false;
    if (s.len > 0 and s[s.len - 1] == '|') {
        end = true;
        s = s[0 .. s.len - 1];
    }
    for (s, 0..) |ch, i| switch (ch) {
        '*' => try o.raw(".*"),
        '^' => try o.raw(if (i == s.len - 1 and !end) "([^a-zA-Z0-9_.%-].*)?$" else "[^a-zA-Z0-9_.%-]"),
        '.', '+', '?', '(', ')', '[', ']', '{', '}', '$', '|' => {
            try o.raw("\\\\");
            try o.buf.append(gpa, ch);
        },
        '\\' => try o.raw("\\\\\\\\"),
        '"' => try o.raw("\\\""),
        0...0x1f, 0x80...0xff => return error.Unsupported,
        else => try o.buf.append(gpa, ch),
    };
    if (end) try o.raw("$");
}

fn get(v: Json, k: []const u8) ?Json {
    if (v != .object) return null;
    return v.object.get(k);
}

fn strings(v: ?Json) ?[]const Json {
    const x = v orelse return null;
    if (x != .array) return null;
    return x.array.items;
}

fn domains(o: *Out, k: []const u8, list: []const Json) !void {
    try o.key(k);
    try o.raw("[");
    for (list) |d| {
        if (d != .string) return error.Unsupported;
        try o.item();
        var tmp: [256]u8 = undefined;
        try o.str(std.fmt.bufPrint(&tmp, "*{s}", .{d.string}) catch return error.Unsupported);
    }
    try o.raw("]");
}

fn resourceTypes(o: *Out, cond: Json) !void {
    var picked: [all_engine_types.len]bool = .{false} ** all_engine_types.len;
    var any = false;
    if (strings(get(cond, "resourceTypes"))) |list| {
        for (list) |t| {
            if (t != .string) return error.Unsupported;
            const mapped = engineTypes(t.string) orelse return error.Unsupported;
            for (mapped) |m| for (all_engine_types, 0..) |e, i| if (std.mem.eql(u8, e, m)) {
                picked[i] = true;
                any = true;
            };
        }
    } else if (strings(get(cond, "excludedResourceTypes"))) |list| {
        picked = .{true} ** all_engine_types.len;
        any = true;
        for (list) |t| {
            if (t != .string) return error.Unsupported;
            const mapped = engineTypes(t.string) orelse return error.Unsupported;
            for (mapped) |m| for (all_engine_types, 0..) |e, i| if (std.mem.eql(u8, e, m)) {
                picked[i] = false;
            };
        }
    } else return;
    if (!any) return error.Unsupported;
    try o.key("resource-type");
    try o.raw("[");
    for (all_engine_types, 0..) |e, i| if (picked[i]) {
        try o.item();
        try o.str(e);
    };
    try o.raw("]");
}

fn trigger(o: *Out, cond: Json, kind: Kind, request_domain: ?[]const u8, method: ?[]const u8) !void {
    const filter = get(cond, "urlFilter");
    const regex = get(cond, "regexFilter");
    if (filter != null and regex != null) return error.Unsupported;
    if (get(cond, "excludedRequestDomains") != null or get(cond, "excludedRequestMethods") != null or get(cond, "excludedTabIds") != null or get(cond, "tabIds") != null) return error.Unsupported;
    try o.key("trigger");
    try o.raw("{");
    var pattern: Out = .{};
    defer pattern.buf.deinit(gpa);
    if (request_domain) |d| {
        if (filter != null or regex != null) return error.Unsupported;
        var tmp: [260]u8 = undefined;
        try filterRegex(&pattern, std.fmt.bufPrint(&tmp, "||{s}^", .{d}) catch return error.Unsupported);
    } else if (regex) |r| {
        if (r != .string) return error.Unsupported;
        for (r.string) |ch| if (ch == '|' or ch == '{') return error.Unsupported;
        try pattern.raw("");
        for (r.string) |ch| switch (ch) {
            '\\' => try pattern.raw("\\\\"),
            '"' => try pattern.raw("\\\""),
            else => try pattern.buf.append(gpa, ch),
        };
    } else if (filter) |f| {
        if (f != .string) return error.Unsupported;
        try filterRegex(&pattern, f.string);
    } else try pattern.raw(".*");
    if (kind == .allow_all) {
        try o.key("url-filter");
        try o.raw("\".*\"");
        try o.key("if-top-url");
        try o.raw("[\"");
        try o.raw(pattern.buf.items);
        try o.raw("\"]");
    } else {
        try o.key("url-filter");
        try o.raw("\"");
        try o.raw(pattern.buf.items);
        try o.raw("\"");
    }
    const sensitive = if (get(cond, "isUrlFilterCaseSensitive")) |v| v == .bool and v.bool else false;
    if (sensitive) {
        try o.key("url-filter-is-case-sensitive");
        try o.raw("true");
    }
    const inc = strings(get(cond, "initiatorDomains")) orelse strings(get(cond, "domains"));
    const exc = strings(get(cond, "excludedInitiatorDomains")) orelse strings(get(cond, "excludedDomains"));
    if (inc != null and exc != null) return error.Unsupported;
    if (inc) |l| try domains(o, "if-domain", l);
    if (exc) |l| try domains(o, "unless-domain", l);
    if (kind != .allow_all) try resourceTypes(o, cond);
    if (get(cond, "domainType")) |t| {
        if (t != .string) return error.Unsupported;
        try o.key("load-type");
        try o.raw(if (std.mem.eql(u8, t.string, "firstParty")) "[\"first-party\"]" else "[\"third-party\"]");
    }
    if (method) |m| {
        try o.key("request-method");
        try o.str(m);
    }
    try o.raw("}");
}

fn headers(o: *Out, k: []const u8, list: ?[]const Json) !void {
    const l = list orelse return;
    try o.key(k);
    try o.raw("[");
    for (l) |h| {
        const op = get(h, "operation") orelse return error.Unsupported;
        const name = get(h, "header") orelse return error.Unsupported;
        if (op != .string or name != .string) return error.Unsupported;
        try o.item();
        try o.raw("{");
        try o.key("operation");
        try o.str(op.string);
        try o.key("header");
        try o.str(name.string);
        if (get(h, "value")) |v| if (v == .string) {
            try o.key("value");
            try o.str(v.string);
        };
        try o.raw("}");
    }
    try o.raw("]");
}

fn transform(o: *Out, t: Json) !void {
    try o.key("transform");
    try o.raw("{");
    const simple = [_][2][]const u8{ .{ "scheme", "scheme" }, .{ "host", "host" }, .{ "port", "port" }, .{ "path", "path" }, .{ "query", "query" }, .{ "fragment", "fragment" }, .{ "username", "username" }, .{ "password", "password" } };
    for (simple) |p| if (get(t, p[0])) |v| if (v == .string) {
        try o.key(p[1]);
        try o.str(v.string);
    };
    if (get(t, "queryTransform")) |q| {
        try o.key("query-transform");
        try o.raw("{");
        if (strings(get(q, "removeParams"))) |l| {
            try o.key("remove-parameters");
            try o.raw("[");
            for (l) |p| if (p == .string) {
                try o.item();
                try o.str(p.string);
            };
            try o.raw("]");
        }
        if (strings(get(q, "addOrReplaceParams"))) |l| {
            try o.key("add-or-replace-parameters");
            try o.raw("[");
            for (l) |p| {
                const k = get(p, "key") orelse continue;
                const v = get(p, "value") orelse continue;
                if (k != .string or v != .string) continue;
                try o.item();
                try o.raw("{");
                try o.key("key");
                try o.str(k.string);
                try o.key("value");
                try o.str(v.string);
                if (get(p, "replaceOnly")) |r| if (r == .bool and r.bool) {
                    try o.key("replace-only");
                    try o.raw("true");
                };
                try o.raw("}");
            }
            try o.raw("]");
        }
        try o.raw("}");
    }
    try o.raw("}");
}

fn action(o: *Out, a: Json, kind: Kind, priority: i64) !void {
    try o.key("action");
    try o.raw("{");
    try o.key("type");
    switch (kind) {
        .block => try o.str("block"),
        .allow, .allow_all => try o.str("ignore-previous-rules"),
        .upgrade => try o.str("make-https"),
        .redirect => {
            try o.str("redirect");
            const r = get(a, "redirect") orelse return error.Unsupported;
            try o.key("redirect");
            try o.raw("{");
            if (get(r, "url")) |u| {
                if (u != .string) return error.Unsupported;
                try o.key("url");
                try o.str(u.string);
            } else if (get(r, "regexSubstitution")) |u| {
                if (u != .string) return error.Unsupported;
                try o.key("regex-substitution");
                try o.str(u.string);
            } else if (get(r, "extensionPath")) |u| {
                if (u != .string) return error.Unsupported;
                try o.key("extension-path");
                try o.str(u.string);
            } else if (get(r, "transform")) |t| {
                try transform(o, t);
            } else return error.Unsupported;
            try o.raw("}");
        },
        .headers => {
            try o.str("modify-headers");
            try o.key("priority");
            var tmp: [24]u8 = undefined;
            try o.raw(std.fmt.bufPrint(&tmp, "{d}", .{@max(priority, 0)}) catch unreachable);
            try headers(o, "request-headers", strings(get(a, "requestHeaders")));
            try headers(o, "response-headers", strings(get(a, "responseHeaders")));
        },
    }
    try o.raw("}");
}

fn kindOf(name: []const u8) ?Kind {
    const map = [_]struct { []const u8, Kind }{
        .{ "block", .block },          .{ "allow", .allow },
        .{ "allowAllRequests", .allow_all }, .{ "upgradeScheme", .upgrade },
        .{ "redirect", .redirect },    .{ "modifyHeaders", .headers },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    return null;
}

fn emit(rules: *std.ArrayList(Rule), r: Json, kind: Kind, priority: i64, id: i64, domain: ?[]const u8, method: ?[]const u8) !void {
    const cond = get(r, "condition") orelse Json{ .null = {} };
    var o: Out = .{};
    errdefer o.buf.deinit(gpa);
    try o.raw("{");
    try trigger(&o, cond, kind, domain, method);
    try action(&o, get(r, "action").?, kind, priority);
    try o.raw("}");
    try rules.append(gpa, .{ .priority = priority, .kind = kind, .id = id, .text = try o.buf.toOwnedSlice(gpa) });
}

fn convertRule(rules: *std.ArrayList(Rule), r: Json) !void {
    const a = get(r, "action") orelse return error.Unsupported;
    const t = get(a, "type") orelse return error.Unsupported;
    if (t != .string) return error.Unsupported;
    const kind = kindOf(t.string) orelse return error.Unsupported;
    const priority: i64 = if (get(r, "priority")) |p| (if (p == .integer) p.integer else 1) else 1;
    const id: i64 = if (get(r, "id")) |p| (if (p == .integer) p.integer else 0) else 0;
    const cond = get(r, "condition") orelse Json{ .null = {} };
    const reqs = strings(get(cond, "requestDomains"));
    const methods = strings(get(cond, "requestMethods"));
    const start = rules.items.len;
    errdefer {
        for (rules.items[start..]) |x| gpa.free(x.text);
        rules.shrinkRetainingCapacity(start);
    }
    const ds: []const Json = reqs orelse &.{Json{ .null = {} }};
    const ms: []const Json = methods orelse &.{Json{ .null = {} }};
    for (ds) |d| for (ms) |m| {
        const dv: ?[]const u8 = if (d == .string) d.string else if (d == .null) null else return error.Unsupported;
        const mv: ?[]const u8 = if (m == .string) m.string else if (m == .null) null else return error.Unsupported;
        try emit(rules, r, kind, priority, id, dv, mv);
    };
}

fn before(_: void, a: Rule, b: Rule) bool {
    if (a.priority != b.priority) return a.priority < b.priority;
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return a.id < b.id;
}

pub fn convert(dnr: []const u8) !Result {
    const parsed = try std.json.parseFromSlice(Json, gpa, dnr, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.NotAnArray;
    var rules: std.ArrayList(Rule) = .empty;
    defer {
        for (rules.items) |r| gpa.free(r.text);
        rules.deinit(gpa);
    }
    var skipped: usize = 0;
    for (parsed.value.array.items) |r| convertRule(&rules, r) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => skipped += 1,
    };
    std.mem.sort(Rule, rules.items, {}, before);
    var o: Out = .{};
    errdefer o.buf.deinit(gpa);
    try o.raw("[");
    for (rules.items) |r| {
        try o.item();
        try o.raw(r.text);
    }
    try o.raw("]");
    return .{ .json = try o.buf.toOwnedSlice(gpa), .converted = rules.items.len, .skipped = skipped };
}

var store: ?*c.WebKitUserContentFilterStore = null;
var filters: ?*c.GHashTable = null;
var managers: ?*c.GPtrArray = null;

fn filterStore() *c.WebKitUserContentFilterStore {
    if (store) |s| return s;
    const path = c.g_build_filename(c.g_get_user_cache_dir(), "fotone", "content-rules", @as([*c]const u8, null));
    defer c.g_free(path);
    store = c.webkit_user_content_filter_store_new(path);
    return store.?;
}

fn table() *c.GHashTable {
    if (filters == null) filters = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, @ptrCast(&c.webkit_user_content_filter_unref));
    return filters.?;
}

fn applyTo(ucm: *c.WebKitUserContentManager) void {
    var it: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&it, table());
    var k: c.gpointer = null;
    var v: c.gpointer = null;
    while (c.g_hash_table_iter_next(&it, &k, &v) != 0) c.webkit_user_content_manager_add_filter(ucm, @ptrCast(v));
}

fn managerGone(_: c.gpointer, gone: [*c]c.GObject) callconv(.c) void {
    if (managers) |m| _ = c.g_ptr_array_remove(m, gone);
}

pub fn track(ucm: *c.WebKitUserContentManager) void {
    if (managers == null) managers = c.g_ptr_array_new();
    if (c.g_ptr_array_find(managers, ucm, null) != 0) return;
    c.g_ptr_array_add(managers, ucm);
    c.g_object_weak_ref(@ptrCast(@alignCast(ucm)), managerGone, null);
    applyTo(ucm);
}

fn each(f: *const fn (*c.WebKitUserContentManager, c.gpointer) void, data: c.gpointer) void {
    const m = managers orelse return;
    var i: c.guint = 0;
    while (i < m.*.len) : (i += 1) f(@ptrCast(@alignCast(m.*.pdata[i])), data);
}

fn addOne(ucm: *c.WebKitUserContentManager, data: c.gpointer) void {
    c.webkit_user_content_manager_add_filter(ucm, @ptrCast(@alignCast(data)));
}

fn removeOne(ucm: *c.WebKitUserContentManager, data: c.gpointer) void {
    c.webkit_user_content_manager_remove_filter_by_id(ucm, @ptrCast(data));
}

pub const Done = ?*const fn (c.gboolean, [*c]const c.GError, c.gpointer) callconv(.c) void;

const Pending = struct {
    id: [*c]u8,
    done: Done,
    data: c.gpointer,
};

fn saved(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(data));
    defer c.g_free(p);
    var err: [*c]c.GError = null;
    const filter = c.webkit_user_content_filter_store_save_finish(@ptrCast(@alignCast(src)), res, &err);
    defer c.g_clear_error(&err);
    if (filter) |f| {
        each(removeOne, p.id);
        _ = c.g_hash_table_replace(table(), p.id, f);
        each(addOne, f);
    } else c.g_free(p.id);
    if (p.done) |d| d(@intFromBool(filter != null), err, p.data);
}

pub fn install(id: [*:0]const u8, dnr: []const u8, done: Done, data: c.gpointer) !Result {
    const r = try convert(dnr);
    const bytes = c.g_bytes_new(r.json.ptr, r.json.len);
    defer c.g_bytes_unref(bytes);
    const p: *Pending = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Pending))));
    p.* = .{ .id = c.g_strdup(id), .done = done, .data = data };
    c.webkit_user_content_filter_store_save(filterStore(), id, bytes, null, saved, p);
    return r;
}

pub fn remove(id: [*:0]const u8) void {
    each(removeOne, @constCast(id));
    _ = c.g_hash_table_remove(table(), id);
    c.webkit_user_content_filter_store_remove(filterStore(), id, null, null, null);
}

test "url filters become content blocker patterns" {
    var o: Out = .{};
    defer o.buf.deinit(gpa);
    try filterRegex(&o, "||ads.example.com^");
    try std.testing.expectEqualStrings("^[a-z][a-z0-9+.-]*://([^/?#]*\\\\.)?ads\\\\.example\\\\.com([^a-zA-Z0-9_.%-].*)?$", o.buf.items);
    o.buf.clearRetainingCapacity();
    try filterRegex(&o, "|https://x.org/*.js|");
    try std.testing.expectEqualStrings("^https://x\\\\.org/.*\\\\.js$", o.buf.items);
}

test "priorities and allow rules keep the declarativeNetRequest order" {
    const r = try convert(
        \\[{"id":1,"priority":1,"action":{"type":"allow"},"condition":{"urlFilter":"good"}},
        \\ {"id":2,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"ads","resourceTypes":["script","image"]}},
        \\ {"id":3,"priority":2,"action":{"type":"block"},"condition":{"requestDomains":["a.org","b.org"]}},
        \\ {"id":4,"action":{"type":"redirect","redirect":{"url":"https://x.org/"}},"condition":{"urlFilter":"r"}},
        \\ {"id":5,"action":{"type":"modifyHeaders","responseHeaders":[{"header":"x-a","operation":"remove"}]},"condition":{"urlFilter":"h"}},
        \\ {"id":6,"action":{"type":"block"},"condition":{"urlFilter":"a","regexFilter":"b"}},
        \\ {"id":7,"action":{"type":"allowAllRequests"},"condition":{"urlFilter":"||trusted.org","resourceTypes":["main_frame"]}}]
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 7), r.converted);
    try std.testing.expectEqual(@as(usize, 1), r.skipped);
    const s = r.json;
    const ads = std.mem.indexOf(u8, s, "\"ads\"").?;
    const good = std.mem.indexOf(u8, s, "\"good\"").?;
    const a_org = std.mem.indexOf(u8, s, "a\\\\.org").?;
    try std.testing.expect(ads < good);
    try std.testing.expect(good < a_org);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"resource-type\":[\"script\",\"image\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"if-top-url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"modify-headers\",\"priority\":1") != null);
}

fn compiled(ok: c.gboolean, err: [*c]const c.GError, data: c.gpointer) callconv(.c) void {
    const flag: *[2]c.gboolean = @ptrCast(@alignCast(data));
    if (ok == 0 and err != null) std.debug.print("compile error: {s}\n", .{err.*.message});
    flag[0] = 1;
    flag[1] = ok;
}

test "the engine compiles what the converter writes" {
    const dir = c.g_dir_make_tmp("fotone-dnr-XXXXXX", null) orelse return error.SkipZigTest;
    defer c.g_free(dir);
    store = c.webkit_user_content_filter_store_new(dir);
    defer {
        c.g_object_unref(store);
        store = null;
    }
    var flag = [2]c.gboolean{ 0, 0 };
    const r = try install("test",
        \\[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"||ads.example^","resourceTypes":["script","xmlhttprequest"],"domainType":"thirdParty"}},
        \\ {"id":2,"priority":2,"action":{"type":"allow"},"condition":{"urlFilter":"|https://ok.example/","initiatorDomains":["ok.example"]}},
        \\ {"id":3,"action":{"type":"upgradeScheme"},"condition":{"requestDomains":["plain.example"]}},
        \\ {"id":4,"action":{"type":"redirect","redirect":{"transform":{"scheme":"https","queryTransform":{"removeParams":["utm_source"]}}}},"condition":{"urlFilter":"utm_source="}},
        \\ {"id":5,"action":{"type":"modifyHeaders","requestHeaders":[{"header":"dnt","operation":"set","value":"1"}]},"condition":{"urlFilter":"*"}},
        \\ {"id":6,"action":{"type":"allowAllRequests"},"condition":{"urlFilter":"||trusted.example^","resourceTypes":["main_frame"]}}]
    , compiled, &flag);
    defer r.deinit();
    const ctx = c.g_main_context_default();
    var spins: usize = 0;
    while (flag[0] == 0 and spins < 2000) : (spins += 1) _ = c.g_main_context_iteration(ctx, 1);
    try std.testing.expect(flag[0] != 0);
    try std.testing.expect(flag[1] != 0);
    _ = c.g_hash_table_remove_all(table());
}
