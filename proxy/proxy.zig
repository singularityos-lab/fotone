const options = @import("options");
const view = if (options.gtk3) @import("view3.zig") else @import("view.zig");
const legacy = if (options.gtk3) @import("legacy.zig") else struct {};
const legacy3 = if (options.gtk3) @import("legacy3.zig") else struct {};
const extra = @import("extra.zig");
const gtkonly = @import("gtkonly.zig");

comptime {
    _ = view;
    _ = legacy;
    _ = legacy3;
    _ = extra;
    _ = gtkonly;
}

fn load() callconv(.c) void {
    _ = gtkonly.webkit_settings_get_type();
    _ = gtkonly.webkit_window_properties_get_type();
    _ = gtkonly.webkit_file_chooser_request_get_type();
    if (options.gtk3) legacy3.load();
}

export const fotone_proxy_load linksection(".init_array") = &load;

test {
    _ = @import("engine");
    _ = gtkonly;
    _ = view;
    _ = legacy;
    _ = legacy3;
    _ = extra;
}
