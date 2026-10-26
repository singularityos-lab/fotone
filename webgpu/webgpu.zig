pub const wk = @import("wk.zig").c;
pub const api = @import("api.zig");
pub const buffer = @import("buffer.zig");
pub const blocks = @import("blocks.zig");
pub const features = @import("features.zig");
pub const objects = @import("objects.zig");
pub const present = @import("present.zig");

comptime {
    _ = api;
    _ = buffer;
    _ = blocks;
    _ = objects;
    _ = present;
}

test {
    @import("std").testing.refAllDecls(@This());
}
