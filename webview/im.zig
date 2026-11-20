const std = @import("std");
const c = @import("c.zig").c;

pub const Context = extern struct {
    parent: c.WPEInputMethodContext,
    gtk: ?*c.GtkIMContext,
    widget: ?*c.GtkWidget,
    surrounding: [*c]u8,
    cursor: c_int,
    anchor: c_int,
};

const Class = extern struct {
    parent: c.WPEInputMethodContextClass,
};

var parent_class: ?*c.GObjectClass = null;
var type_id: c.GType = 0;

fn of(p: anytype) *Context {
    return @ptrCast(@alignCast(p));
}

fn wpe(ctx: *Context) *c.WPEInputMethodContext {
    return &ctx.parent;
}

pub fn getType() c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(&type_id)) != 0) {
        const t = c.g_type_register_static_simple(c.wpe_input_method_context_get_type(), c.g_intern_static_string("SitInputMethodContext"), @sizeOf(Class), classInit, @sizeOf(Context), instanceInit, 0);
        c.g_once_init_leave_pointer(@ptrCast(&type_id), @ptrFromInt(t));
    }
    return type_id;
}

pub fn create(view: ?*c.WPEView) *c.WPEInputMethodContext {
    const ctx = of(c.g_object_new(getType(), "view", view, @as([*c]const u8, null)));
    if (view) |v| c.g_object_set_data(@ptrCast(v), "sit-im", ctx);
    return wpe(ctx);
}

pub fn lookup(view: ?*c.WPEView) ?*c.WPEInputMethodContext {
    const v = view orelse return null;
    const ctx: ?*Context = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(v), "sit-im")));
    return if (ctx) |x| wpe(x) else null;
}

pub fn bind(context: ?*c.WPEInputMethodContext, wd: *c.GtkWidget) void {
    const ctx = of(context orelse return);
    if (ctx.widget == wd) return;
    if (ctx.widget) |old| c.g_object_remove_weak_pointer(@ptrCast(old), @ptrCast(&ctx.widget));
    ctx.widget = wd;
    c.g_object_add_weak_pointer(@ptrCast(wd), @ptrCast(&ctx.widget));
    c.gtk_im_context_set_client_widget(ctx.gtk, wd);
}

pub fn filter(context: ?*c.WPEInputMethodContext, ev: ?*c.GdkEvent) bool {
    const ctx = of(context orelse return false);
    return c.gtk_im_context_filter_keypress(ctx.gtk, ev) != 0;
}

fn syncPurpose(ctx: *Context) void {
    const purpose = c.wpe_input_method_context_get_input_purpose(wpe(ctx));
    const hints = c.wpe_input_method_context_get_input_hints(wpe(ctx));
    const p: c.GtkInputPurpose = if (purpose <= c.WPE_INPUT_PURPOSE_TERMINAL) @intCast(purpose) else c.GTK_INPUT_PURPOSE_FREE_FORM;
    c.g_object_set(@ptrCast(ctx.gtk), "input-purpose", p, "input-hints", @as(c.GtkInputHints, @intCast(hints)), @as([*c]const u8, null));
}

fn onPurpose(_: ?*c.GObject, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    syncPurpose(of(data));
}

fn onCommit(_: ?*c.GtkIMContext, text: [*c]const u8, data: c.gpointer) callconv(.c) void {
    c.g_signal_emit_by_name(@ptrCast(wpe(of(data))), "committed", text);
}

fn onPreeditStart(_: ?*c.GtkIMContext, data: c.gpointer) callconv(.c) void {
    c.g_signal_emit_by_name(@ptrCast(wpe(of(data))), "preedit-started");
}

fn onPreeditChanged(_: ?*c.GtkIMContext, data: c.gpointer) callconv(.c) void {
    c.g_signal_emit_by_name(@ptrCast(wpe(of(data))), "preedit-changed");
}

fn onPreeditEnd(_: ?*c.GtkIMContext, data: c.gpointer) callconv(.c) void {
    c.g_signal_emit_by_name(@ptrCast(wpe(of(data))), "preedit-finished");
}

pub fn utf16Units(text: []const u8) c.guint {
    var units: c.guint = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| units += if (cp > 0xFFFF) 2 else 1;
    return units;
}

pub fn charsToBytes(text: []const u8, from: usize, chars: c_int) usize {
    var pos = from;
    var left = chars;
    if (left < 0) {
        while (left < 0 and pos > 0) : (left += 1) {
            pos -= 1;
            while (pos > 0 and (text[pos] & 0xC0) == 0x80) pos -= 1;
        }
    } else {
        while (left > 0 and pos < text.len) : (left -= 1) {
            pos += std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
        }
    }
    return @min(pos, text.len);
}

fn onDeleteSurrounding(_: ?*c.GtkIMContext, offset: c_int, n_chars: c_int, data: c.gpointer) callconv(.c) c.gboolean {
    const ctx = of(data);
    const text: []const u8 = if (ctx.surrounding) |s| std.mem.span(s) else "";
    const cur: usize = @min(@as(usize, @intCast(@max(ctx.cursor, 0))), text.len);
    const start = charsToBytes(text, cur, offset);
    const end = charsToBytes(text, start, @max(n_chars, 0));
    const off16: c_int = if (start < cur) -@as(c_int, @intCast(utf16Units(text[start..cur]))) else @intCast(utf16Units(text[cur..start]));
    c.g_signal_emit_by_name(@ptrCast(wpe(ctx)), "delete-surrounding", off16, utf16Units(text[start..end]));
    return 1;
}

fn onRetrieveSurrounding(im: ?*c.GtkIMContext, data: c.gpointer) callconv(.c) c.gboolean {
    const ctx = of(data);
    const text = ctx.surrounding orelse return 0;
    c.gtk_im_context_set_surrounding_with_selection(im, text, -1, ctx.cursor, ctx.anchor);
    return 1;
}

fn getPreeditString(context: [*c]c.WPEInputMethodContext, text: [*c][*c]c.gchar, underlines: [*c][*c]c.GList, cursor: [*c]c.guint) callconv(.c) void {
    const ctx = of(context);
    var str: [*c]u8 = null;
    var pos: c_int = 0;
    c.gtk_im_context_get_preedit_string(ctx.gtk, &str, null, &pos);
    const len: c.guint = if (str) |s| @intCast(c.g_utf8_strlen(s, -1)) else 0;
    if (underlines != null) {
        underlines.* = if (len > 0) c.g_list_prepend(null, c.wpe_input_method_underline_new(0, len)) else null;
    }
    if (cursor != null) cursor.* = @intCast(@max(pos, 0));
    if (text != null) text.* = str else c.g_free(str);
}

fn filterKeyEvent(_: [*c]c.WPEInputMethodContext, _: ?*c.WPEEvent) callconv(.c) c.gboolean {
    return 0;
}

fn focusIn(context: [*c]c.WPEInputMethodContext) callconv(.c) void {
    const ctx = of(context);
    syncPurpose(ctx);
    c.gtk_im_context_focus_in(ctx.gtk);
}

fn focusOut(context: [*c]c.WPEInputMethodContext) callconv(.c) void {
    c.gtk_im_context_focus_out(of(context).gtk);
}

fn setCursorArea(context: [*c]c.WPEInputMethodContext, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) void {
    const area = c.GdkRectangle{ .x = x, .y = y, .width = width, .height = height };
    c.gtk_im_context_set_cursor_location(of(context).gtk, &area);
}

fn setSurrounding(context: [*c]c.WPEInputMethodContext, text: [*c]const c.gchar, length: c.guint, cursor: c.guint, selection: c.guint) callconv(.c) void {
    const ctx = of(context);
    c.g_free(ctx.surrounding);
    ctx.surrounding = c.g_strndup(text, length);
    ctx.cursor = @intCast(cursor);
    ctx.anchor = @intCast(selection);
    c.gtk_im_context_set_surrounding_with_selection(ctx.gtk, ctx.surrounding, -1, ctx.cursor, ctx.anchor);
}

fn reset(context: [*c]c.WPEInputMethodContext) callconv(.c) void {
    c.gtk_im_context_reset(of(context).gtk);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const ctx = of(o);
    if (ctx.gtk) |im| {
        _ = c.g_signal_handlers_disconnect_matched(@ptrCast(im), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, ctx);
        c.gtk_im_context_set_client_widget(im, null);
        c.g_object_unref(im);
        ctx.gtk = null;
    }
    if (ctx.widget) |wd| {
        c.g_object_remove_weak_pointer(@ptrCast(wd), @ptrCast(&ctx.widget));
        ctx.widget = null;
    }
    if (c.wpe_input_method_context_get_view(wpe(ctx))) |v| {
        if (c.g_object_get_data(@ptrCast(v), "sit-im") == @as(c.gpointer, ctx)) c.g_object_set_data(@ptrCast(v), "sit-im", null);
    }
    parent_class.?.dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_free(of(o).surrounding);
    parent_class.?.finalize.?(o);
}

fn instanceInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const ctx = of(inst);
    const im = c.gtk_im_multicontext_new();
    ctx.gtk = im;
    _ = c.g_signal_connect_data(im, "commit", @ptrCast(&onCommit), ctx, null, 0);
    _ = c.g_signal_connect_data(im, "preedit-start", @ptrCast(&onPreeditStart), ctx, null, 0);
    _ = c.g_signal_connect_data(im, "preedit-changed", @ptrCast(&onPreeditChanged), ctx, null, 0);
    _ = c.g_signal_connect_data(im, "preedit-end", @ptrCast(&onPreeditEnd), ctx, null, 0);
    _ = c.g_signal_connect_data(im, "delete-surrounding", @ptrCast(&onDeleteSurrounding), ctx, null, 0);
    _ = c.g_signal_connect_data(im, "retrieve-surrounding", @ptrCast(&onRetrieveSurrounding), ctx, null, 0);
    _ = c.g_signal_connect_data(inst, "notify::input-purpose", @ptrCast(&onPurpose), ctx, null, 0);
    _ = c.g_signal_connect_data(inst, "notify::input-hints", @ptrCast(&onPurpose), ctx, null, 0);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    oc.dispose = dispose;
    oc.finalize = finalize;
    const ic: *c.WPEInputMethodContextClass = @ptrCast(@alignCast(klass));
    ic.get_preedit_string = getPreeditString;
    ic.filter_key_event = filterKeyEvent;
    ic.focus_in = focusIn;
    ic.focus_out = focusOut;
    ic.set_cursor_area = setCursorArea;
    ic.set_surrounding = setSurrounding;
    ic.reset = reset;
}

test "delete-surrounding counts UTF-16 units around the cursor" {
    const text = "ab\u{1F600}cd";
    try std.testing.expectEqual(@as(usize, 2), charsToBytes(text, 6, -1));
    try std.testing.expectEqual(@as(c.guint, 2), utf16Units(text[2..6]));
    try std.testing.expectEqual(@as(usize, 7), charsToBytes(text, 6, 1));
    try std.testing.expectEqual(@as(usize, 0), charsToBytes(text, 2, -5));
}

test "purpose values line up with GTK" {
    try std.testing.expectEqual(@as(c_int, c.GTK_INPUT_PURPOSE_TERMINAL), @as(c_int, c.WPE_INPUT_PURPOSE_TERMINAL));
    try std.testing.expectEqual(@as(c_int, c.GTK_INPUT_HINT_PRIVATE), @as(c_int, c.WPE_INPUT_HINT_PRIVATE));
    try std.testing.expectEqual(@as(c_int, c.GTK_INPUT_HINT_INHIBIT_OSK), @as(c_int, c.WPE_INPUT_HINT_INHIBIT_OSK));
}
