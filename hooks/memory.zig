const std = @import("std");

pub const Level = enum(c_int) { none = 0, pressure = 1, critical = 2 };

pub const USED_PRESSURE = 90;
pub const USED_CRITICAL = 95;
pub const SOME_PRESSURE = 10.0;
pub const FULL_CRITICAL = 5.0;

pub const Stall = struct { some: f64 = 0, full: f64 = 0 };

fn avg10(line: []const u8) ?f64 {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |f| {
        if (std.mem.startsWith(u8, f, "avg10=")) return std.fmt.parseFloat(f64, f["avg10=".len..]) catch null;
    }
    return null;
}

pub fn parse(text: []const u8) Stall {
    var s: Stall = .{};
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "some ")) s.some = avg10(line) orelse 0;
        if (std.mem.startsWith(u8, line, "full ")) s.full = avg10(line) orelse 0;
    }
    return s;
}

pub fn level(used: c_int, stall: Stall) Level {
    if (used >= USED_CRITICAL or stall.full >= FULL_CRITICAL) return .critical;
    if (used >= USED_PRESSURE or stall.some >= SOME_PRESSURE) return .pressure;
    return .none;
}

fn read() Stall {
    const linux = std.os.linux;
    const rc = linux.open("/proc/pressure/memory", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return .{};
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [256]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return .{};
    return parse(buf[0..n]);
}

pub export fn fotone_memory_pressure_level(used: c_int) c_int {
    return @intFromEnum(level(used, read()));
}

pub const Region = struct { start: usize, end: usize };

pub fn anonymous(line: []const u8) ?Region {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const range = fields.next() orelse return null;
    const perms = fields.next() orelse return null;
    if (!std.mem.eql(u8, perms, "rw-p")) return null;
    for (0..3) |_| _ = fields.next() orelse return null;
    if (fields.next()) |name| {
        if (!std.mem.eql(u8, name, "[heap]") and !std.mem.startsWith(u8, name, "[anon")) return null;
    }
    const dash = std.mem.indexOfScalar(u8, range, '-') orelse return null;
    return .{
        .start = std.fmt.parseInt(usize, range[0..dash], 16) catch return null,
        .end = std.fmt.parseInt(usize, range[dash + 1 ..], 16) catch return null,
    };
}

pub export fn fotone_memory_page_out() usize {
    const linux = std.os.linux;
    const rc = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return 0;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [65536]u8 = undefined;
    var kept: usize = 0;
    var total: usize = 0;
    while (true) {
        const n = linux.read(fd, buf[kept..].ptr, buf.len - kept);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        const data = buf[0 .. kept + n];
        const last = std.mem.lastIndexOfScalar(u8, data, '\n') orelse break;
        var lines = std.mem.tokenizeScalar(u8, data[0..last], '\n');
        while (lines.next()) |line| {
            const r = anonymous(line) orelse continue;
            if (linux.errno(linux.madvise(@ptrFromInt(r.start), r.end - r.start, linux.MADV.PAGEOUT)) == .SUCCESS) total += r.end - r.start;
        }
        kept = data.len - last - 1;
        std.mem.copyForwards(u8, buf[0..kept], data[last + 1 ..]);
    }
    return total;
}

test "only private anonymous memory is paged out" {
    try std.testing.expectEqual(Region{ .start = 0x1000, .end = 0x3000 }, anonymous("1000-3000 rw-p 00000000 00:00 0 ").?);
    try std.testing.expectEqual(Region{ .start = 0x5000, .end = 0x6000 }, anonymous("5000-6000 rw-p 00000000 00:00 0                          [heap]").?);
    try std.testing.expect(anonymous("1000-3000 r-xp 00000000 08:01 12 /usr/lib/libc.so.6") == null);
    try std.testing.expect(anonymous("1000-3000 rw-s 00000000 00:05 7 /dev/dri/renderD128") == null);
    try std.testing.expect(anonymous("1000-3000 rw-p 00000000 00:00 0 [stack]") == null);
    try std.testing.expect(anonymous("1000-3000 rw-p 00001000 08:01 12 /usr/lib/libc.so.6") == null);
}

test "paging out the test process does not fail" {
    _ = fotone_memory_page_out();
}

test "stall lines parse both averages" {
    const s = parse("some avg10=12.50 avg60=3.00 avg300=1.00 total=1234\nfull avg10=6.00 avg60=0.00 avg300=0.00 total=12\n");
    try std.testing.expectEqual(@as(f64, 12.5), s.some);
    try std.testing.expectEqual(@as(f64, 6.0), s.full);
    try std.testing.expectEqual(@as(f64, 0), parse("garbage").some);
}

test "the live file reads without failing" {
    _ = fotone_memory_pressure_level(0);
}

test "stalls raise the level before memory fills" {
    try std.testing.expectEqual(Level.none, level(40, .{}));
    try std.testing.expectEqual(Level.pressure, level(40, .{ .some = 15 }));
    try std.testing.expectEqual(Level.critical, level(40, .{ .some = 30, .full = 8 }));
    try std.testing.expectEqual(Level.pressure, level(91, .{}));
    try std.testing.expectEqual(Level.critical, level(96, .{}));
}
