const options = @import("options");

pub const c = if (options.gtk3) @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("webkit2gtk.h");
}) else @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("webkitgtk.h");
});
