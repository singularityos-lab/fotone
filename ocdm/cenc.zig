const std = @import("std");
const Aes128 = std.crypto.core.aes.Aes128;

pub const Mode = enum { ctr, cbcs };

pub const Subsample = struct {
    clear: u32,
    encrypted: u32,
};

pub const Pattern = struct {
    crypt: u32 = 0,
    skip: u32 = 0,
};

fn bump(counter: *[16]u8) void {
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        counter[i] +%= 1;
        if (counter[i] != 0) break;
    }
}

const Ctr = struct {
    ctx: std.crypto.core.aes.AesEncryptCtx(Aes128),
    counter: [16]u8,
    stream: [16]u8 = undefined,
    used: usize = 16,

    fn apply(s: *Ctr, data: []u8) void {
        for (data) |*b| {
            if (s.used == 16) {
                s.ctx.encrypt(&s.stream, &s.counter);
                bump(&s.counter);
                s.used = 0;
            }
            b.* ^= s.stream[s.used];
            s.used += 1;
        }
    }
};

fn cbcRun(ctx: anytype, iv: *[16]u8, data: []u8, pattern: Pattern) void {
    const blocks = data.len / 16;
    var b: usize = 0;
    const cycle = pattern.crypt + pattern.skip;
    while (b < blocks) : (b += 1) {
        if (cycle != 0 and pattern.crypt != 0 and (b % cycle) >= pattern.crypt) continue;
        const block = data[b * 16 ..][0..16];
        var saved: [16]u8 = undefined;
        @memcpy(&saved, block);
        var out: [16]u8 = undefined;
        ctx.decrypt(&out, block);
        for (&out, iv) |*o, v| o.* ^= v;
        @memcpy(block, &out);
        iv.* = saved;
    }
}

pub fn decrypt(mode: Mode, key: [16]u8, iv_in: []const u8, data: []u8, subsamples: []const Subsample, pattern: Pattern) !void {
    var iv: [16]u8 = .{0} ** 16;
    if (iv_in.len != 8 and iv_in.len != 16) return error.BadIv;
    @memcpy(iv[0..iv_in.len], iv_in);
    const whole = [_]Subsample{.{ .clear = 0, .encrypted = @intCast(data.len) }};
    const list = if (subsamples.len == 0) whole[0..] else subsamples;
    var total: usize = 0;
    for (list) |s| total += @as(usize, s.clear) + s.encrypted;
    if (total > data.len) return error.BadSubsamples;
    switch (mode) {
        .ctr => {
            var s: Ctr = .{ .ctx = Aes128.initEnc(key), .counter = iv };
            var at: usize = 0;
            for (list) |sub| {
                at += sub.clear;
                s.apply(data[at..][0..sub.encrypted]);
                at += sub.encrypted;
            }
        },
        .cbcs => {
            const ctx = Aes128.initDec(key);
            var at: usize = 0;
            for (list) |sub| {
                at += sub.clear;
                var chain = iv;
                cbcRun(ctx, &chain, data[at..][0..sub.encrypted], pattern);
                at += sub.encrypted;
            }
        },
    }
}

pub fn parseSubsamples(raw: []const u8, count: usize, out: []Subsample) ![]Subsample {
    if (count > out.len or raw.len < count * 6) return error.BadSubsamples;
    for (0..count) |i| {
        const p = raw[i * 6 ..][0..6];
        out[i] = .{ .clear = std.mem.readInt(u16, p[0..2], .big), .encrypted = std.mem.readInt(u32, p[2..6], .big) };
    }
    return out[0..count];
}

fn encryptCtrForTest(key: [16]u8, iv: [16]u8, data: []u8) void {
    var s: Ctr = .{ .ctx = Aes128.initEnc(key), .counter = iv };
    s.apply(data);
}

test "cenc ctr decrypts across subsamples with one running counter" {
    const key = [_]u8{0x11} ** 16;
    var iv8 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var plain: [64]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = @intCast(i);
    var enc = plain;
    var iv16: [16]u8 = .{0} ** 16;
    @memcpy(iv16[0..8], &iv8);
    var joined: [40]u8 = undefined;
    @memcpy(joined[0..20], enc[4..24]);
    @memcpy(joined[20..40], enc[34..54]);
    encryptCtrForTest(key, iv16, &joined);
    @memcpy(enc[4..24], joined[0..20]);
    @memcpy(enc[34..54], joined[20..40]);
    const subs = [_]Subsample{ .{ .clear = 4, .encrypted = 20 }, .{ .clear = 10, .encrypted = 20 } };
    try decrypt(.ctr, key, &iv8, &enc, &subs, .{});
    try std.testing.expectEqualSlices(u8, &plain, &enc);
}

test "cbcs decrypts the pattern and leaves skipped and partial blocks clear" {
    const key = [_]u8{0x22} ** 16;
    const iv = [_]u8{0x33} ** 16;
    var plain: [16 * 12 + 5]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = @truncate(i * 7);
    var enc = plain;
    const ctx = Aes128.initEnc(key);
    var chain = iv;
    var b: usize = 0;
    while (b < 12) : (b += 1) {
        if (b % 10 >= 1) continue;
        const block = enc[b * 16 ..][0..16];
        var x: [16]u8 = undefined;
        for (&x, block, chain) |*o, p, v| o.* = p ^ v;
        ctx.encrypt(block, &x);
        chain = block.*;
    }
    try decrypt(.cbcs, key, &iv, &enc, &.{}, .{ .crypt = 1, .skip = 9 });
    try std.testing.expectEqualSlices(u8, &plain, &enc);
}

test "subsample tables are big endian pairs" {
    const raw = [_]u8{ 0, 5, 0, 0, 1, 0, 0, 2, 0, 0, 0, 16 };
    var out: [4]Subsample = undefined;
    const s = try parseSubsamples(&raw, 2, &out);
    try std.testing.expectEqual(@as(u32, 5), s[0].clear);
    try std.testing.expectEqual(@as(u32, 256), s[0].encrypted);
    try std.testing.expectEqual(@as(u32, 16), s[1].encrypted);
}
