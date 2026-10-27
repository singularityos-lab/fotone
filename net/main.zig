const std = @import("std");
const h3 = @import("h3.zig");
const c = h3.c;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        _ = c.fprintf(c.stderr, "usage: fotone-h3 https://host/path\n");
        return 2;
    }
    var response = h3.Response{};
    h3.get(arena, args[1], 15 * std.time.ns_per_s, &response) catch |err| {
        _ = c.fprintf(c.stderr, "fotone-h3: %s\n", @errorName(err).ptr);
        return 1;
    };
    _ = c.printf("status=%u bytes=%zu handshake_ms=%.1f total_ms=%.1f\n", @as(c_uint, response.status), response.body.items.len, @as(f64, @floatFromInt(response.handshake_ns)) / 1e6, @as(f64, @floatFromInt(response.total_ns)) / 1e6);
    return if (response.status >= 200 and response.status < 400) 0 else 1;
}

test {
    _ = h3;
}
