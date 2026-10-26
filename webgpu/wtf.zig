const std = @import("std");

pub const FLAG_8BIT: u32 = 1 << 2;
pub const REF_STEP: u32 = 2;

pub const StringImpl = extern struct {
    refs: u32,
    len: u32,
    data: ?*const anyopaque,
    hash_flags: u32,
};

pub const String = extern struct {
    impl: ?*StringImpl = null,
};

pub fn Vector(comptime T: type) type {
    return extern struct {
        buffer: ?[*]T,
        capacity: u32,
        size: u32,

        pub fn items(v: *const @This()) []T {
            const b = v.buffer orelse return &.{};
            return b[0..v.size];
        }
    };
}

pub fn Optional(comptime T: type) type {
    return extern struct {
        value: T,
        engaged: bool,

        pub fn get(o: *const @This()) ?T {
            return if (o.engaged) o.value else null;
        }
    };
}

pub fn Span(comptime T: type) type {
    return extern struct {
        ptr: ?[*]T,
        len: usize,

        pub fn of(s: []T) @This() {
            return .{ .ptr = if (s.len == 0) null else s.ptr, .len = s.len };
        }

        pub fn slice(s: @This()) []T {
            const p = s.ptr orelse return &.{};
            return p[0..s.len];
        }
    };
}

pub fn ConstSpan(comptime T: type) type {
    return extern struct {
        ptr: ?[*]const T,
        len: usize,

        pub fn slice(s: @This()) []const T {
            const p = s.ptr orelse return &.{};
            return p[0..s.len];
        }
    };
}

pub fn utf8(gpa: std.mem.Allocator, s: String) ![:0]u8 {
    const impl = s.impl orelse return gpa.dupeZ(u8, "");
    const data = impl.data orelse return gpa.dupeZ(u8, "");
    if (impl.hash_flags & FLAG_8BIT != 0) {
        const bytes: [*]const u8 = @ptrCast(data);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (bytes[0..impl.len]) |ch| {
            if (ch < 0x80) {
                try out.append(gpa, ch);
            } else {
                try out.append(gpa, 0xc0 | (ch >> 6));
                try out.append(gpa, 0x80 | (ch & 0x3f));
            }
        }
        return out.toOwnedSliceSentinel(gpa, 0);
    }
    const units: [*]const u16 = @ptrCast(@alignCast(data));
    return std.unicode.utf16LeToUtf8AllocZ(gpa, units[0..impl.len]) catch |e| switch (e) {
        error.OutOfMemory => e,
        else => gpa.dupeZ(u8, ""),
    };
}

pub fn deref(s: *String) void {
    const impl = s.impl orelse return;
    s.impl = null;
    const old = @atomicRmw(u32, &impl.refs, .Sub, REF_STEP, .monotonic);
    if (old == REF_STEP) destroy(impl);
}

const DESTROY = "_ZN3WTF10StringImpl7destroyEPS0_";
const FROM_UTF8 = "_ZN3WTF6String33fromUTF8ReplacingInvalidSequencesESt4spanIKDuLm18446744073709551615EE";

fn lookup(comptime F: type, comptime name: []const u8) ?*const F {
    const S = struct {
        const symbol = name;
        var p = std.atomic.Value(?*const anyopaque).init(null);
    };
    if (S.p.load(.acquire)) |p| return @ptrCast(@alignCast(p));
    const p = std.c.dlsym(null, @ptrCast((name ++ "\x00").ptr)) orelse return null;
    S.p.store(p, .release);
    return @ptrCast(@alignCast(p));
}

fn destroy(impl: *StringImpl) void {
    const f = lookup(fn (*StringImpl) callconv(.c) void, DESTROY) orelse return;
    f(impl);
}

pub fn fromUtf8(text: []const u8) String {
    var s: String = .{};
    const f = lookup(fn (*String, ?[*]const u8, usize) callconv(.c) *String, FROM_UTF8) orelse return s;
    _ = f(&s, if (text.len == 0) null else text.ptr, text.len);
    return s;
}

test "8-bit and 16-bit strings convert to utf-8" {
    const gpa = std.testing.allocator;
    const latin = "caf\xe9";
    var a = StringImpl{ .refs = 3, .len = 4, .data = latin, .hash_flags = FLAG_8BIT };
    const s8 = try utf8(gpa, .{ .impl = &a });
    defer gpa.free(s8);
    try std.testing.expectEqualStrings("café", s8);
    const wide = [_]u16{ 'f', 'n', ' ', 0x03bb };
    var b = StringImpl{ .refs = 3, .len = 4, .data = &wide, .hash_flags = 0 };
    const s16 = try utf8(gpa, .{ .impl = &b });
    defer gpa.free(s16);
    try std.testing.expectEqualStrings("fn λ", s16);
    const empty = try utf8(gpa, .{});
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
