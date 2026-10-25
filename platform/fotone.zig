pub const display = @import("display.zig");
pub const view = @import("view.zig");
pub const toplevel = @import("toplevel.zig");

comptime {
    _ = display;
    _ = view;
    _ = toplevel;
}

test {
    _ = display;
    _ = view;
    _ = toplevel;
}
