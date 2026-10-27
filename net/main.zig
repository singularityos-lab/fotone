const std = @import("std");
const h3 = @import("h3.zig");
const c = h3.c;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        _ = c.fprintf(c.stderr, "usage: fotone-h3 https://host/path [count]\n");
        return 2;
    }
    const url = h3.parseUrl(args[1]) orelse return 2;
    const count = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 1;
    const start = h3.now();
    const conn = h3.Conn.open(arena, url.host, url.port) catch |err| {
        _ = c.fprintf(c.stderr, "fotone-h3: %s\n", @errorName(err).ptr);
        return 1;
    };
    defer conn.close();
    const responses = try arena.alloc(h3.Response, count);
    const requests = try arena.alloc(h3.Request, count);
    for (responses, requests) |*resp, *r| {
        resp.* = .{ .gpa = arena };
        r.* = .{ .method = "GET", .path = url.path, .headers = "user-agent\x00fotone-h3\x00", .sink = resp.sink() };
    }
    h3.fetch(conn, requests, 30 * std.time.ns_per_s) catch |err| {
        _ = c.fprintf(c.stderr, "fotone-h3: %s\n", @errorName(err).ptr);
        return 1;
    };
    var bytes: usize = 0;
    var ok: usize = 0;
    for (responses) |resp| {
        bytes += resp.body.items.len;
        if (resp.ok and resp.status >= 200 and resp.status < 400) ok += 1;
    }
    const total = h3.now() - start;
    _ = c.printf("status=%u ok=%zu/%zu bytes=%zu handshake_ms=%.1f total_ms=%.1f\n", @as(c_uint, responses[0].status), ok, count, bytes, @as(f64, @floatFromInt(conn.handshake_ns)) / 1e6, @as(f64, @floatFromInt(total)) / 1e6);
    return if (ok == count) 0 else 1;
}

test {
    _ = h3;
}
