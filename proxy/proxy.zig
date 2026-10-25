const view = @import("view.zig");
const extra = @import("extra.zig");
const gtkonly = @import("gtkonly.zig");

comptime {
    _ = view;
    _ = extra;
    _ = gtkonly;
}

fn load() callconv(.c) void {
    _ = gtkonly.webkit_settings_get_type();
    _ = gtkonly.webkit_window_properties_get_type();
    _ = gtkonly.webkit_file_chooser_request_get_type();
}

export const fotone_proxy_load linksection(".init_array") = &load;

test {
    _ = @import("engine.zig");
    _ = gtkonly;
    _ = view;
    _ = extra;
}
