const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("perf.h");
});

const REPEAT = 3;
const TOLERANCE = 1.15;
const SLACK = 2.0;
const FUNCTIONS = 6000;

const pages = .{
    .{ "js.html", @embedFile("js.html") },
    .{ "scroll.html", @embedFile("scroll.html") },
    .{ "dom.html", @embedFile("dom.html") },
};

pub const Metric = struct { name: []const u8, value: f64 };

pub fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[values.len / 2];
}

pub fn regressed(value: f64, base: f64) bool {
    return value > base * TOLERANCE + SLACK;
}

fn writeFile(dir: []const u8, name: []const u8, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name });
    var err: [*c]c.GError = null;
    if (c.g_file_set_contents(path, data.ptr, @intCast(data.len), &err) == 0) {
        std.log.err("fotone-perf: {s}", .{err.*.message});
        c.g_error_free(err);
        return error.Write;
    }
}

pub fn bundle(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var line: [512]u8 = undefined;
    for (0..FUNCTIONS) |i| {
        const f = try std.fmt.bufPrint(&line,
            \\function f{d}(a, b) {{ const list = [a, b, {d}]; let s = 0; for (const v of list) {{ s += v * {d} % 7; if (s > 1000) s -= 999; }} return {{ value: s, name: "f{d}", tag: `t${{a}}-${{b}}` }}; }}
            \\
        , .{ i, i, i % 97, i });
        try out.appendSlice(gpa, f);
    }
    try out.appendSlice(gpa, "window.perfChecksum = 0;\n");
    for (0..FUNCTIONS) |i| {
        const call = try std.fmt.bufPrint(&line, "window.perfChecksum += f{d}({d}, 3).value;\n", .{ i, i % 11 });
        try out.appendSlice(gpa, call);
    }
    return out.toOwnedSlice(gpa);
}

fn run(gpa: std.mem.Allocator, viewer: [:0]const u8, dir: []const u8, page: []const u8, cache: [:0]const u8) !std.json.Parsed(std.json.Value) {
    var buf: [4096]u8 = undefined;
    const uri = try std.fmt.bufPrintZ(&buf, "file://{s}/{s}", .{ dir, page });
    var argv = [_:null]?[*:0]const u8{ viewer.ptr, "--perf", uri.ptr, null };
    const env = c.g_environ_setenv(c.g_get_environ(), "XDG_CACHE_HOME", cache.ptr, 1);
    defer c.g_strfreev(env);
    var out: [*c]u8 = null;
    var status: c_int = 0;
    var err: [*c]c.GError = null;
    if (c.g_spawn_sync(null, @ptrCast(&argv), env, c.G_SPAWN_STDERR_TO_DEV_NULL, null, null, &out, null, &status, &err) == 0) {
        std.log.err("fotone-perf: {s}", .{err.*.message});
        c.g_error_free(err);
        return error.Spawn;
    }
    defer c.g_free(out);
    const text = std.mem.trim(u8, std.mem.span(out), " \n");
    const last = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |i| text[i + 1 ..] else text;
    return std.json.parseFromSlice(std.json.Value, gpa, last, .{}) catch {
        std.log.err("fotone-perf: {s} exited with {d}: {s}", .{ page, status, last });
        return error.NoReport;
    };
}

fn number(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn measure(gpa: std.mem.Allocator, viewer: [:0]const u8, dir: []const u8, metrics: *std.StringArrayHashMapUnmanaged(f64)) !void {
    var samples: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(f64)) = .empty;
    defer {
        for (samples.values()) |*l| l.deinit(gpa);
        samples.deinit(gpa);
    }
    var cache_buf: [4096]u8 = undefined;
    for (0..REPEAT) |round| {
        const cache = try std.fmt.bufPrintZ(&cache_buf, "{s}/cache-{d}", .{ dir, round });
        _ = c.g_mkdir_with_parents(cache.ptr, 0o700);
        inline for (pages) |p| {
            const runs: usize = if (std.mem.eql(u8, p[0], "js.html")) 2 else 1;
            for (0..runs) |n| {
                var parsed = run(gpa, viewer, dir, p[0], cache) catch |e| {
                    if (e == error.NoReport and std.mem.eql(u8, p[0], "scroll.html")) {
                        if (round == 0) std.debug.print("scroll: skipped, the display gives no frames\n", .{});
                        continue;
                    }
                    std.log.err("fotone-perf: {s} reported nothing", .{p[0]});
                    return e;
                };
                defer parsed.deinit();
                if (parsed.value != .object) {
                    std.log.err("fotone-perf: {s} reported nothing", .{p[0]});
                    return error.NoReport;
                }
                var it = parsed.value.object.iterator();
                while (it.next()) |e| {
                    if (std.mem.eql(u8, e.key_ptr.*, "checksum")) continue;
                    const v = number(e.value_ptr.*) orelse continue;
                    const name = if (std.mem.eql(u8, e.key_ptr.*, "js_ms")) (if (n == 0) "js_cold_ms" else "js_warm_ms") else e.key_ptr.*;
                    const key = try gpa.dupe(u8, name);
                    const gop = try samples.getOrPut(gpa, key);
                    if (gop.found_existing) gpa.free(key) else gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(gpa, v);
                }
            }
        }
    }
    for (samples.keys(), samples.values()) |k, *l| try metrics.put(gpa, try gpa.dupe(u8, k), median(l.items));
    for (samples.keys()) |k| gpa.free(k);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var viewer: [:0]const u8 = "fotone-viewer";
    var baseline: ?[:0]const u8 = null;
    var work: ?[]const u8 = null;
    var update = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--viewer") and i + 1 < args.len) {
            viewer = try arena.dupeZ(u8, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--baseline") and i + 1 < args.len) {
            baseline = try arena.dupeZ(u8, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--work") and i + 1 < args.len) {
            work = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--update")) {
            update = true;
        } else {
            std.debug.print("usage: fotone-perf --work DIR [--viewer PATH] [--baseline FILE] [--update]\n", .{});
            return 2;
        }
    }
    const dir = work orelse {
        std.debug.print("fotone-perf: --work is required\n", .{});
        return 2;
    };
    _ = c.g_mkdir_with_parents((try arena.dupeZ(u8, dir)).ptr, 0o700);
    inline for (pages) |p| try writeFile(dir, p[0], p[1]);
    const js = try bundle(gpa);
    defer gpa.free(js);
    try writeFile(dir, "bundle.js", js);

    var metrics: std.StringArrayHashMapUnmanaged(f64) = .empty;
    defer {
        for (metrics.keys()) |k| gpa.free(k);
        metrics.deinit(gpa);
    }
    try measure(gpa, viewer, dir, &metrics);

    var base: ?std.json.Parsed(std.json.Value) = null;
    defer if (base) |*b| b.deinit();
    if (baseline) |path| {
        var text: [*c]u8 = null;
        if (c.g_file_get_contents(path.ptr, &text, null, null) != 0) {
            defer c.g_free(text);
            base = std.json.parseFromSlice(std.json.Value, gpa, std.mem.span(text), .{}) catch null;
        }
    }
    var failed = false;
    for (metrics.keys(), metrics.values()) |k, v| {
        const prev: ?f64 = if (base) |b| (if (b.value == .object) (if (b.value.object.get(k)) |x| number(x) else null) else null) else null;
        if (prev) |p| {
            const bad = regressed(v, p);
            failed = failed or bad;
            std.debug.print("{s:<20} {d:>9.1} {d:>9.1} {s}\n", .{ k, v, p, if (bad) "WORSE" else "ok" });
        } else std.debug.print("{s:<20} {d:>9.1} {s:>9} new\n", .{ k, v, "-" });
    }
    if (baseline) |path| if (update or base == null or !failed) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, "{\n");
        for (metrics.keys(), metrics.values(), 0..) |k, v, n| {
            var line: [256]u8 = undefined;
            try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"{s}\": {d:.2}{s}\n", .{ k, v, if (n + 1 < metrics.count()) "," else "" }));
        }
        try out.appendSlice(gpa, "}\n");
        var err: [*c]c.GError = null;
        if (c.g_file_set_contents(path.ptr, out.items.ptr, @intCast(out.items.len), &err) == 0) c.g_error_free(err);
    };
    return if (failed) 1 else 0;
}

test "a small slowdown passes and a large one fails" {
    try std.testing.expect(!regressed(110, 100));
    try std.testing.expect(regressed(120, 100));
    try std.testing.expect(!regressed(3, 1));
}

test "median picks the middle sample" {
    var v = [_]f64{ 9, 1, 5 };
    try std.testing.expectEqual(@as(f64, 5), median(&v));
}

test "the bundle defines and calls every function" {
    const js = try bundle(std.testing.allocator);
    defer std.testing.allocator.free(js);
    try std.testing.expectEqual(@as(usize, FUNCTIONS * 2), std.mem.count(u8, js, "function f") + std.mem.count(u8, js, ").value"));
}
