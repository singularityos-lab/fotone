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
