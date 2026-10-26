const std = @import("std");

pub const DEALLOCATING: i32 = 0x0001;
pub const REFCOUNT_MASK: i32 = 0xfffe;
pub const NEEDS_FREE: i32 = 1 << 24;
pub const HAS_COPY_DISPOSE: i32 = 1 << 25;
pub const IS_GLOBAL: i32 = 1 << 28;

const FIELD_IS_OBJECT = 3;
const FIELD_IS_BLOCK = 7;
const FIELD_IS_BYREF = 8;
const BYREF_CALLER = 128;

pub export var _NSConcreteMallocBlock: [32]?*anyopaque = .{null} ** 32;
pub export var _NSConcreteStackBlock: [32]?*anyopaque = .{null} ** 32;
pub export var _NSConcreteGlobalBlock: [32]?*anyopaque = .{null} ** 32;

pub const Descriptor = extern struct {
    reserved: usize,
    size: usize,
    copy: ?*const fn (dst: *anyopaque, src: *const anyopaque) callconv(.c) void,
    dispose: ?*const fn (src: *const anyopaque) callconv(.c) void,
};

pub const Literal = extern struct {
    isa: ?*anyopaque,
    flags: i32,
    reserved: i32,
    invoke: ?*const anyopaque,
    descriptor: *const Descriptor,
};

const Byref = extern struct {
    isa: ?*anyopaque,
    forwarding: *Byref,
    flags: i32,
    size: u32,
    keep: ?*const fn (dst: *Byref, src: *Byref) callconv(.c) void,
    destroy: ?*const fn (src: *Byref) callconv(.c) void,
};

const BYREF_HAS_HELPERS: i32 = 1 << 25;

fn retain(flags: *i32) void {
    var old = @atomicLoad(i32, flags, .monotonic);
    while (true) {
        if (old & REFCOUNT_MASK == REFCOUNT_MASK) return;
        old = @cmpxchgWeak(i32, flags, old, old + 2, .monotonic, .monotonic) orelse return;
    }
}

fn release(flags: *i32) bool {
    var old = @atomicLoad(i32, flags, .monotonic);
    while (true) {
        if (old & REFCOUNT_MASK == REFCOUNT_MASK) return false;
        if (old & REFCOUNT_MASK == 0) return false;
        const last = old & REFCOUNT_MASK == 2;
        const next = if (last) (old - 2) | DEALLOCATING else old - 2;
        old = @cmpxchgWeak(i32, flags, old, next, .release, .monotonic) orelse {
            if (last) @atomicStore(i32, flags, next, .seq_cst);
            return last;
        };
    }
}

pub export fn _Block_copy(arg: ?*const anyopaque) ?*anyopaque {
    const p = arg orelse return null;
    const b: *Literal = @ptrCast(@alignCast(@constCast(p)));
    if (b.flags & NEEDS_FREE != 0) {
        retain(&b.flags);
        return b;
    }
    if (b.flags & IS_GLOBAL != 0) return b;
    const size = b.descriptor.size;
    const mem = std.c.malloc(size) orelse return null;
    const dst: [*]u8 = @ptrCast(mem);
    const src: [*]const u8 = @ptrCast(b);
    @memcpy(dst[0..size], src[0..size]);
    const n: *Literal = @ptrCast(@alignCast(mem));
    n.flags = (n.flags & ~(REFCOUNT_MASK | DEALLOCATING)) | NEEDS_FREE | 2;
    n.isa = @ptrCast(&_NSConcreteMallocBlock);
    if (b.flags & HAS_COPY_DISPOSE != 0) {
        if (b.descriptor.copy) |c| c(n, b);
    }
    return n;
}

pub export fn _Block_release(arg: ?*const anyopaque) void {
    const p = arg orelse return;
    const b: *Literal = @ptrCast(@alignCast(@constCast(p)));
    if (b.flags & NEEDS_FREE == 0) return;
    if (!release(&b.flags)) return;
    if (b.flags & HAS_COPY_DISPOSE != 0) {
        if (b.descriptor.dispose) |d| d(b);
    }
    std.c.free(b);
}

fn byrefCopy(arg: *Byref) *Byref {
    const src = arg.forwarding;
    if (src.flags & NEEDS_FREE != 0) {
        retain(&src.flags);
        return src;
    }
    const mem = std.c.malloc(src.size) orelse @panic("block byref copy");
    const dst: *Byref = @ptrCast(@alignCast(mem));
    dst.* = src.*;
    dst.flags = (src.flags & ~(REFCOUNT_MASK | DEALLOCATING)) | NEEDS_FREE | 4;
    dst.forwarding = dst;
    src.forwarding = dst;
    if (src.flags & BYREF_HAS_HELPERS != 0) {
        if (src.keep) |k| k(dst, src);
    } else {
        const tail = @sizeOf(Byref) - 2 * @sizeOf(usize);
        const d: [*]u8 = @ptrCast(dst);
        const s: [*]const u8 = @ptrCast(src);
        @memcpy(d[tail..src.size], s[tail..src.size]);
    }
    return dst;
}

fn byrefRelease(arg: *Byref) void {
    const b = arg.forwarding;
    if (b.flags & NEEDS_FREE == 0) return;
    if (!release(&b.flags)) return;
    if (b.flags & BYREF_HAS_HELPERS != 0) {
        if (b.destroy) |d| d(b);
    }
    std.c.free(b);
}

pub export fn _Block_object_assign(dst: *?*anyopaque, object: ?*const anyopaque, flags: c_int) void {
    const o = object orelse {
        dst.* = null;
        return;
    };
    switch (flags & (FIELD_IS_BYREF | FIELD_IS_BLOCK | FIELD_IS_OBJECT | BYREF_CALLER)) {
        FIELD_IS_BLOCK => dst.* = _Block_copy(o),
        FIELD_IS_BYREF => dst.* = byrefCopy(@ptrCast(@alignCast(@constCast(o)))),
        else => dst.* = @constCast(o),
    }
}

pub export fn _Block_object_dispose(object: ?*const anyopaque, flags: c_int) void {
    const o = object orelse return;
    switch (flags & (FIELD_IS_BYREF | FIELD_IS_BLOCK | FIELD_IS_OBJECT | BYREF_CALLER)) {
        FIELD_IS_BLOCK => _Block_release(o),
        FIELD_IS_BYREF => byrefRelease(@ptrCast(@alignCast(@constCast(o)))),
        else => {},
    }
}

pub fn invoke(comptime F: type, block: *const anyopaque) *const F {
    const b: *const Literal = @ptrCast(@alignCast(block));
    return @ptrCast(@alignCast(b.invoke.?));
}

pub fn Closure(comptime Ctx: type, comptime run: fn (*Ctx) void) type {
    return extern struct {
        literal: Literal,
        ctx: [@sizeOf(Ctx)]u8 align(@alignOf(Ctx)),

        const Self = @This();

        fn context(self: *Self) *Ctx {
            return @ptrCast(&self.ctx);
        }

        fn call(self: *Self) callconv(.c) void {
            run(self.context());
        }

        fn dispose(p: *const anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(@constCast(p)));
            if (@hasDecl(Ctx, "deinit")) self.context().deinit();
        }

        const descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(Self), .copy = null, .dispose = dispose };

        pub fn create(ctx: Ctx) ?*Self {
            const mem = std.c.malloc(@sizeOf(Self)) orelse return null;
            const self: *Self = @ptrCast(@alignCast(mem));
            self.* = .{
                .literal = .{ .isa = @ptrCast(&_NSConcreteMallocBlock), .flags = NEEDS_FREE | HAS_COPY_DISPOSE | 2, .reserved = 0, .invoke = @ptrCast(&call), .descriptor = &descriptor },
                .ctx = undefined,
            };
            self.context().* = ctx;
            return self;
        }
    };
}

pub fn ClosureWith(comptime Ctx: type, comptime Arg: type, comptime run: fn (*Ctx, Arg) void) type {
    return extern struct {
        literal: Literal,
        ctx: [@sizeOf(Ctx)]u8 align(@alignOf(Ctx)),

        const Self = @This();

        fn context(self: *Self) *Ctx {
            return @ptrCast(&self.ctx);
        }

        fn call(self: *Self, arg: Arg) callconv(.c) void {
            run(self.context(), arg);
        }

        fn dispose(p: *const anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(@constCast(p)));
            if (@hasDecl(Ctx, "deinit")) self.context().deinit();
        }

        const descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(Self), .copy = null, .dispose = dispose };

        pub fn create(ctx: Ctx) ?*Self {
            const mem = std.c.malloc(@sizeOf(Self)) orelse return null;
            const self: *Self = @ptrCast(@alignCast(mem));
            self.* = .{
                .literal = .{ .isa = @ptrCast(&_NSConcreteMallocBlock), .flags = NEEDS_FREE | HAS_COPY_DISPOSE | 2, .reserved = 0, .invoke = @ptrCast(&call), .descriptor = &descriptor },
                .ctx = undefined,
            };
            self.context().* = ctx;
            return self;
        }
    };
}

var disposed: usize = 0;

fn countDispose(_: *const anyopaque) callconv(.c) void {
    disposed += 1;
}

test "malloc blocks are reference counted" {
    const desc = Descriptor{ .reserved = 0, .size = @sizeOf(Literal), .copy = null, .dispose = countDispose };
    const mem = std.c.malloc(@sizeOf(Literal)).?;
    const b: *Literal = @ptrCast(@alignCast(mem));
    b.* = .{ .isa = @ptrCast(&_NSConcreteMallocBlock), .flags = NEEDS_FREE | HAS_COPY_DISPOSE | 2, .reserved = 0, .invoke = null, .descriptor = &desc };
    disposed = 0;
    const c = _Block_copy(b);
    try std.testing.expect(c == @as(?*anyopaque, b));
    _Block_release(b);
    try std.testing.expectEqual(@as(usize, 0), disposed);
    _Block_release(c);
    try std.testing.expectEqual(@as(usize, 1), disposed);
}

test "stack blocks are moved to the heap" {
    const desc = Descriptor{ .reserved = 0, .size = @sizeOf(Literal), .copy = null, .dispose = countDispose };
    var b = Literal{ .isa = @ptrCast(&_NSConcreteStackBlock), .flags = HAS_COPY_DISPOSE, .reserved = 0, .invoke = null, .descriptor = &desc };
    disposed = 0;
    const c = _Block_copy(&b).?;
    try std.testing.expect(c != @as(*anyopaque, &b));
    const h: *Literal = @ptrCast(@alignCast(c));
    try std.testing.expect(h.flags & NEEDS_FREE != 0);
    _Block_release(c);
    try std.testing.expectEqual(@as(usize, 1), disposed);
}

const Counter = extern struct {
    n: *u32,

    fn bump(self: *Counter) void {
        self.n.* += 1;
    }
};

test "closures run through the block invoke pointer" {
    var n: u32 = 0;
    const C = Closure(Counter, Counter.bump);
    const b = C.create(.{ .n = &n }).?;
    invoke(fn (*anyopaque) callconv(.c) void, b)(b);
    invoke(fn (*anyopaque) callconv(.c) void, b)(b);
    _Block_release(b);
    try std.testing.expectEqual(@as(u32, 2), n);
}
