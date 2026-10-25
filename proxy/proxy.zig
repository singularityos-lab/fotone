const view = @import("view.zig");
const extra = @import("extra.zig");
const gtkonly = @import("gtkonly.zig");

comptime {
    _ = view;
    _ = extra;
    _ = gtkonly;
}

test {
    _ = @import("engine.zig");
    _ = gtkonly;
    _ = view;
    _ = extra;
}
