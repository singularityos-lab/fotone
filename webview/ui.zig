const std = @import("std");
const c = @import("c.zig").c;
const nearby = @import("nearby.zig");
const capabilities = @import("capabilities.zig");
const contacts = @import("contacts.zig");
const perms = @import("perms.zig");

fn tr(s: [*:0]const u8) [*c]const u8 {
    return c.g_dgettext("gtk40", s);
}

fn window(w: *c.GtkWidget) ?*c.GtkWindow {
    const root = c.gtk_widget_get_root(w) orelse return null;
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(root)), c.gtk_window_get_type()) == 0) return null;
    return @ptrCast(@alignCast(root));
}

pub fn windowOf(w: *c.GtkWidget) ?*c.GtkWindow {
    return window(w);
}

fn dialogChosen(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const d: *c.WebKitScriptDialog = @ptrCast(@alignCast(data));
    const i = c.gtk_alert_dialog_choose_finish(@ptrCast(@alignCast(src)), res, null);
    const kind = c.webkit_script_dialog_get_dialog_type(d);
    if (kind != c.WEBKIT_SCRIPT_DIALOG_ALERT) c.webkit_script_dialog_confirm_set_confirmed(d, @intFromBool(i == 1));
    c.webkit_script_dialog_close(d);
    c.webkit_script_dialog_unref(d);
}

const Form = struct {
    win: *c.GtkWindow,
    box: *c.GtkWidget,
    entries: [2]?*c.GtkWidget = .{ null, null },
    done: *const fn (*Form, bool) void,
    data: c.gpointer,
    answered: bool = false,

    fn new(w: *c.GtkWidget, title: [*c]const u8, message: [*c]const u8, done: *const fn (*Form, bool) void, data: c.gpointer) *Form {
        const f: *Form = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Form))));
        const win: *c.GtkWindow = @ptrCast(@alignCast(c.gtk_window_new()));
        c.gtk_window_set_modal(win, 1);
        c.gtk_window_set_resizable(win, 0);
        c.gtk_window_set_transient_for(win, window(w));
        c.gtk_window_set_title(win, title);
        c.gtk_window_set_default_size(win, 360, -1);
        c.gtk_widget_add_css_class(@ptrCast(win), "dialog");
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
        c.gtk_widget_set_margin_top(box, 18);
        c.gtk_widget_set_margin_bottom(box, 18);
        c.gtk_widget_set_margin_start(box, 18);
        c.gtk_widget_set_margin_end(box, 18);
        const label = c.gtk_label_new(message);
        c.gtk_label_set_wrap(@ptrCast(label), 1);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_box_append(@ptrCast(box), label);
        c.gtk_window_set_child(win, box);
        f.* = .{ .win = win, .box = box, .done = done, .data = data };
        _ = c.g_signal_connect_data(win, "close-request", @ptrCast(&closeRequest), f, null, 0);
        return f;
    }

    fn entry(f: *Form, i: usize, initial: [*c]const u8, hidden: bool) void {
        const e = c.gtk_entry_new();
        if (initial != null) c.gtk_editable_set_text(@ptrCast(e), initial);
        if (hidden) c.gtk_entry_set_visibility(@ptrCast(e), 0);
        c.gtk_entry_set_activates_default(@ptrCast(e), 1);
        c.gtk_box_append(@ptrCast(f.box), e);
        f.entries[i] = e;
    }

    fn text(f: *Form, i: usize) [*c]const u8 {
        const e = f.entries[i] orelse return null;
        return c.gtk_editable_get_text(@ptrCast(e));
    }

    fn show(f: *Form, accept: [*c]const u8) void {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_set_halign(row, c.GTK_ALIGN_END);
        const cancel = c.gtk_button_new_with_mnemonic(tr("_Cancel"));
        const ok = c.gtk_button_new_with_mnemonic(accept);
        c.gtk_widget_add_css_class(ok, "suggested-action");
        _ = c.g_signal_connect_data(cancel, "clicked", @ptrCast(&cancelled), f, null, 0);
        _ = c.g_signal_connect_data(ok, "clicked", @ptrCast(&accepted), f, null, 0);
        c.gtk_box_append(@ptrCast(row), cancel);
        c.gtk_box_append(@ptrCast(row), ok);
        c.gtk_box_append(@ptrCast(f.box), row);
        c.gtk_window_set_default_widget(f.win, ok);
        c.gtk_window_present(f.win);
    }

    fn finish(f: *Form, ok: bool) void {
        if (f.answered) return;
        f.answered = true;
        f.done(f, ok);
        c.gtk_window_destroy(f.win);
        c.g_free(f);
    }

    fn accepted(_: ?*c.GtkButton, data: c.gpointer) callconv(.c) void {
        finish(@ptrCast(@alignCast(data)), true);
    }

    fn cancelled(_: ?*c.GtkButton, data: c.gpointer) callconv(.c) void {
        finish(@ptrCast(@alignCast(data)), false);
    }

    fn closeRequest(_: ?*c.GtkWindow, data: c.gpointer) callconv(.c) c.gboolean {
        finish(@ptrCast(@alignCast(data)), false);
        return 1;
    }
};

fn promptDone(f: *Form, ok: bool) void {
    const d: *c.WebKitScriptDialog = @ptrCast(@alignCast(f.data));
    if (ok) c.webkit_script_dialog_prompt_set_text(d, f.text(0));
    c.webkit_script_dialog_close(d);
    c.webkit_script_dialog_unref(d);
}

pub fn scriptDialog(_: ?*c.WebKitWebView, d: ?*c.WebKitScriptDialog, data: c.gpointer) callconv(.c) c.gboolean {
    const w: *c.GtkWidget = @ptrCast(@alignCast(data));
    const dialog = d orelse return 0;
    _ = c.webkit_script_dialog_ref(dialog);
    const message = c.webkit_script_dialog_get_message(dialog);
    switch (c.webkit_script_dialog_get_dialog_type(dialog)) {
        c.WEBKIT_SCRIPT_DIALOG_PROMPT => {
            const f = Form.new(w, null, message, promptDone, dialog);
            f.entry(0, c.webkit_script_dialog_prompt_get_default_text(dialog), false);
            f.show(tr("_OK"));
        },
        else => |kind| {
            const a = c.gtk_alert_dialog_new("%s", message);
            defer c.g_object_unref(a);
            if (kind == c.WEBKIT_SCRIPT_DIALOG_ALERT) {
                const labels = [_:null]?[*:0]const u8{tr("_OK")};
                c.gtk_alert_dialog_set_buttons(a, @ptrCast(&labels));
                c.gtk_alert_dialog_set_cancel_button(a, 0);
            } else {
                const labels = [_:null]?[*:0]const u8{ tr("_Cancel"), tr("_OK") };
                c.gtk_alert_dialog_set_buttons(a, @ptrCast(&labels));
                c.gtk_alert_dialog_set_cancel_button(a, 0);
                c.gtk_alert_dialog_set_default_button(a, 1);
            }
            c.gtk_alert_dialog_choose(a, window(w), null, dialogChosen, dialog);
        },
    }
    return 1;
}

fn authDone(f: *Form, ok: bool) void {
    const r: *c.WebKitAuthenticationRequest = @ptrCast(@alignCast(f.data));
    defer c.g_object_unref(r);
    if (!ok) return c.webkit_authentication_request_cancel(r);
    const cred = c.webkit_credential_new(f.text(0), f.text(1), c.WEBKIT_CREDENTIAL_PERSISTENCE_FOR_SESSION);
    defer c.webkit_credential_free(cred);
    c.webkit_authentication_request_authenticate(r, cred);
}

pub fn authenticate(_: ?*c.WebKitWebView, r: ?*c.WebKitAuthenticationRequest, data: c.gpointer) callconv(.c) c.gboolean {
    const w: *c.GtkWidget = @ptrCast(@alignCast(data));
    const req = r orelse return 0;
    _ = c.g_object_ref(req);
    const host = c.webkit_authentication_request_get_host(req);
    const realm = c.webkit_authentication_request_get_realm(req);
    const message = c.g_strdup_printf("%s\n%s", host, if (realm != null) realm else @as([*c]const u8, ""));
    defer c.g_free(message);
    const f = Form.new(w, host, message, authDone, req);
    var user: [*c]const u8 = null;
    if (c.webkit_authentication_request_get_proposed_credential(req)) |cred| {
        defer c.webkit_credential_free(cred);
        user = c.g_intern_string(c.webkit_credential_get_username(cred));
    }
    f.entry(0, user, false);
    f.entry(1, null, true);
    f.show(tr("_OK"));
    return 1;
}

fn filesChosen(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const r: *c.WebKitFileChooserRequest = @ptrCast(@alignCast(data));
    defer c.g_object_unref(r);
    const fd: *c.GtkFileDialog = @ptrCast(@alignCast(src));
    const model: ?*c.GListModel = if (c.webkit_file_chooser_request_get_select_multiple(r) != 0)
        c.gtk_file_dialog_open_multiple_finish(fd, res, null)
    else blk: {
        const file = c.gtk_file_dialog_open_finish(fd, res, null) orelse break :blk null;
        const store = c.g_list_store_new(c.g_file_get_type());
        c.g_list_store_append(store, file);
        c.g_object_unref(file);
        break :blk @ptrCast(store);
    };
    const list = model orelse return c.webkit_file_chooser_request_cancel(r);
    defer c.g_object_unref(list);
    const n = c.g_list_model_get_n_items(list);
    const paths: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc0((n + 1) * @sizeOf([*c]u8))));
    defer c.g_strfreev(paths);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const file: *c.GFile = @ptrCast(@alignCast(c.g_list_model_get_item(list, i)));
        defer c.g_object_unref(file);
        paths[i] = c.g_file_get_path(file);
    }
    c.webkit_file_chooser_request_select_files(r, @ptrCast(paths));
}

pub fn runFileChooser(_: ?*c.WebKitWebView, r: ?*c.WebKitFileChooserRequest, data: c.gpointer) callconv(.c) c.gboolean {
    const w: *c.GtkWidget = @ptrCast(@alignCast(data));
    const req = r orelse return 0;
    _ = c.g_object_ref(req);
    const fd = c.gtk_file_dialog_new();
    defer c.g_object_unref(fd);
    const mimes = c.webkit_file_chooser_request_get_mime_types(req);
    if (mimes != null and mimes[0] != null) {
        const filter = c.gtk_file_filter_new();
        defer c.g_object_unref(filter);
        var i: usize = 0;
        while (mimes[i] != null) : (i += 1) c.gtk_file_filter_add_mime_type(filter, mimes[i]);
        c.gtk_file_dialog_set_default_filter(fd, filter);
    }
    if (c.webkit_file_chooser_request_get_select_multiple(req) != 0)
        c.gtk_file_dialog_open_multiple(fd, window(w), null, filesChosen, req)
    else
        c.gtk_file_dialog_open(fd, window(w), null, filesChosen, req);
    return 1;
}

const Options = struct {
    menu: *c.WebKitOptionMenu,
    popover: *c.GtkWidget,
    chosen: bool = false,
};

fn optionActivated(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: c.gpointer) callconv(.c) void {
    const o: *Options = @ptrCast(@alignCast(data));
    o.chosen = true;
    c.webkit_option_menu_activate_item(o.menu, @intCast(c.gtk_list_box_row_get_index(row)));
    c.gtk_popover_popdown(@ptrCast(o.popover));
}

fn unparentNow(data: c.gpointer) callconv(.c) c.gboolean {
    const p: *c.GtkWidget = @ptrCast(@alignCast(data));
    if (c.gtk_widget_get_parent(p) != null) c.gtk_widget_unparent(p);
    c.g_object_unref(p);
    return 0;
}

fn unparentLater(p: *c.GtkWidget) void {
    _ = c.g_idle_add(unparentNow, c.g_object_ref(p));
}

fn optionsClosed(p: ?*c.GtkPopover, data: c.gpointer) callconv(.c) void {
    const o: *Options = @ptrCast(@alignCast(data));
    if (!o.chosen) c.webkit_option_menu_close(o.menu);
    c.g_object_unref(o.menu);
    unparentLater(@ptrCast(p.?));
    c.g_free(o);
}

pub fn showOptionMenu(_: ?*c.WebKitWebView, m: ?*c.WebKitOptionMenu, rect: ?*c.WebKitRectangle, data: c.gpointer) callconv(.c) c.gboolean {
    const w: *c.GtkWidget = @ptrCast(@alignCast(data));
    const menu = m orelse return 0;
    const popover = c.gtk_popover_new();
    const o: *Options = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Options))));
    o.* = .{ .menu = @ptrCast(@alignCast(c.g_object_ref(menu))), .popover = popover };
    const list = c.gtk_list_box_new();
    c.gtk_list_box_set_activate_on_single_click(@ptrCast(list), 1);
    var selected: ?*c.GtkWidget = null;
    var i: c.guint = 0;
    while (i < c.webkit_option_menu_get_n_items(menu)) : (i += 1) {
        const item = c.webkit_option_menu_get_item(menu, i);
        const label = c.gtk_label_new(c.webkit_option_menu_item_get_label(item));
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        const row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_child(@ptrCast(row), label);
        const group = c.webkit_option_menu_item_is_group_label(item) != 0;
        if (group) c.gtk_widget_add_css_class(label, "heading");
        if (c.webkit_option_menu_item_is_group_child(item) != 0) c.gtk_widget_set_margin_start(label, 12);
        c.gtk_list_box_row_set_activatable(@ptrCast(row), @intFromBool(!group and c.webkit_option_menu_item_is_enabled(item) != 0));
        c.gtk_list_box_row_set_selectable(@ptrCast(row), @intFromBool(!group));
        if (c.webkit_option_menu_item_get_tooltip(item)) |tip| c.gtk_widget_set_tooltip_text(row, tip);
        c.gtk_list_box_append(@ptrCast(list), row);
        if (c.webkit_option_menu_item_is_selected(item) != 0) selected = row;
    }
    if (selected) |row| c.gtk_list_box_select_row(@ptrCast(list), @ptrCast(row));
    const scroll = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroll), 1);
    c.gtk_scrolled_window_set_max_content_height(@ptrCast(scroll), 360);
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), list);
    c.gtk_popover_set_child(@ptrCast(popover), scroll);
    c.gtk_popover_set_has_arrow(@ptrCast(popover), 0);
    c.gtk_widget_add_css_class(popover, "menu");
    if (rect) |r| {
        const area: c.GdkRectangle = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
        c.gtk_popover_set_pointing_to(@ptrCast(popover), &area);
        c.gtk_widget_set_size_request(scroll, r.width, -1);
    }
    c.gtk_popover_set_position(@ptrCast(popover), c.GTK_POS_BOTTOM);
    c.gtk_widget_set_parent(popover, w);
    _ = c.g_signal_connect_data(list, "row-activated", @ptrCast(&optionActivated), o, null, 0);
    _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&optionsClosed), o, null, c.G_CONNECT_AFTER);
    c.gtk_popover_popup(@ptrCast(popover));
    return 1;
}

fn addItems(group: *c.GSimpleActionGroup, menu: *c.GMenu, items: ?*c.GList) void {
    var section = c.g_menu_new();
    var l = items;
    while (l) |node| : (l = node.*.next) {
        const item: *c.WebKitContextMenuItem = @ptrCast(@alignCast(node.*.data));
        if (c.webkit_context_menu_item_is_separator(item) != 0) {
            if (c.g_menu_model_get_n_items(@ptrCast(@alignCast(section))) > 0) c.g_menu_append_section(menu, null, @ptrCast(@alignCast(section)));
            c.g_object_unref(section);
            section = c.g_menu_new();
            continue;
        }
        const title = c.webkit_context_menu_item_get_title(item);
        if (c.webkit_context_menu_item_get_submenu(item)) |sub| {
            const child = c.g_menu_new().?;
            defer c.g_object_unref(child);
            addItems(group, child, c.webkit_context_menu_get_items(sub));
            c.g_menu_append_submenu(section, title, @ptrCast(@alignCast(child)));
            continue;
        }
        const action = c.webkit_context_menu_item_get_gaction(item) orelse continue;
        c.g_action_map_add_action(@ptrCast(group), action);
        const name = c.g_strconcat("ctx.", c.g_action_get_name(action), @as([*c]const u8, null));
        defer c.g_free(name);
        const mi = c.g_menu_item_new(title, null);
        defer c.g_object_unref(mi);
        c.g_menu_item_set_action_and_target_value(mi, name, c.webkit_context_menu_item_get_gaction_target(item));
        c.g_menu_append_item(section, mi);
    }
    if (c.g_menu_model_get_n_items(@ptrCast(@alignCast(section))) > 0) c.g_menu_append_section(menu, null, @ptrCast(@alignCast(section)));
    c.g_object_unref(section);
}

fn contextClosed(p: ?*c.GtkPopover, _: c.gpointer) callconv(.c) void {
    const w = c.gtk_widget_get_parent(@ptrCast(p));
    c.gtk_widget_insert_action_group(w, "ctx", null);
    unparentLater(@ptrCast(p.?));
}

fn sendToDevice(_: ?*c.GSimpleAction, param: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    nearby.shareUrl(c.g_variant_get_string(param, null), @ptrCast(data));
}

fn addNearby(group: *c.GSimpleActionGroup, model: *c.GMenu, uri: [*c]const u8) void {
    if (uri == null) return;
    var buf: [16]nearby.Device = undefined;
    const n = nearby.devices(&buf);
    if (n == 0) return;
    defer nearby.free(buf[0..n]);
    const action = c.g_simple_action_new("nearby-share", c.g_variant_type_checked_("s"));
    defer c.g_object_unref(action);
    const url = c.g_strdup(uri);
    c.g_object_set_data_full(@ptrCast(group), "fotone-nearby-url", url, c.g_free);
    _ = c.g_signal_connect_data(action, "activate", @ptrCast(&sendToDevice), url, null, 0);
    c.g_action_map_add_action(@ptrCast(group), @ptrCast(action));
    const sub = c.g_menu_new();
    defer c.g_object_unref(sub);
    for (buf[0..n]) |d| {
        const item = c.g_menu_item_new(d.name, null);
        defer c.g_object_unref(item);
        c.g_menu_item_set_action_and_target_value(item, "ctx.nearby-share", c.g_variant_new_string(d.id));
        c.g_menu_append_item(sub, item);
    }
    const section = c.g_menu_new();
    defer c.g_object_unref(section);
    c.g_menu_append_submenu(section, c.g_dgettext("fotone", "Send to Device"), @ptrCast(@alignCast(sub)));
    c.g_menu_append_section(model, null, @ptrCast(@alignCast(section)));
}

fn selectionRead(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    const v = c.webkit_web_view_evaluate_javascript_finish(@ptrCast(@alignCast(src)), res, null) orelse return;
    defer c.g_object_unref(v);
    const text = c.jsc_value_to_string(v);
    defer c.g_free(text);
    if (text == null or text[0] == 0) return;
    capabilities.call(capabilities.TRANSLATE, "Translate", c.g_variant_new("(s)", text));
}

fn translate(_: ?*c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const web: *c.WebKitWebView = @ptrCast(@alignCast(data));
    c.webkit_web_view_evaluate_javascript(web, "window.getSelection().toString()", -1, "fotone-translate", null, null, selectionRead, null);
}

fn addTranslate(group: *c.GSimpleActionGroup, model: *c.GMenu, web: ?*c.WebKitWebView) void {
    const v = web orelse return;
    const p = capabilities.find(capabilities.TRANSLATE) orelse return;
    p.free();
    const action = c.g_simple_action_new("translate", null);
    defer c.g_object_unref(action);
    _ = c.g_signal_connect_data(action, "activate", @ptrCast(&translate), v, null, 0);
    c.g_action_map_add_action(@ptrCast(group), @ptrCast(action));
    const section = c.g_menu_new();
    defer c.g_object_unref(section);
    c.g_menu_append(section, c.g_dgettext("fotone", "Translate"), "ctx.translate");
    c.g_menu_append_section(model, null, @ptrCast(@alignCast(section)));
}

var cards: [contacts.MAX]contacts.Card = undefined;

fn fillContact(_: ?*c.GSimpleAction, param: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    contacts.fill(@ptrCast(@alignCast(data)), param orelse return);
}

fn addContacts(group: *c.GSimpleActionGroup, model: *c.GMenu, web: ?*c.WebKitWebView) void {
    const v = web orelse return;
    const n = contacts.load(&cards);
    if (n == 0) return;
    const action = c.g_simple_action_new("contact-fill", c.g_variant_type_checked_("a{ss}"));
    defer c.g_object_unref(action);
    _ = c.g_signal_connect_data(action, "activate", @ptrCast(&fillContact), v, null, 0);
    c.g_action_map_add_action(@ptrCast(group), @ptrCast(action));
    const sub = c.g_menu_new();
    defer c.g_object_unref(sub);
    for (cards[0..n]) |*card| {
        const name = card.get(.name);
        const label = c.g_strndup(name.ptr, name.len);
        defer c.g_free(label);
        const item = c.g_menu_item_new(label, null);
        defer c.g_object_unref(item);
        c.g_menu_item_set_action_and_target_value(item, "ctx.contact-fill", card.variant());
        c.g_menu_append_item(sub, item);
    }
    const section = c.g_menu_new();
    defer c.g_object_unref(section);
    c.g_menu_append_submenu(section, c.g_dgettext("fotone", "Fill from Contacts"), @ptrCast(@alignCast(sub)));
    c.g_menu_append_section(model, null, @ptrCast(@alignCast(section)));
}

pub fn contextMenu(w: *c.GtkWidget, menu: *c.WebKitContextMenu, x: f64, y: f64, uri: [*c]const u8, selection: ?*c.WebKitWebView, editable: ?*c.WebKitWebView) bool {
    if (c.webkit_context_menu_get_n_items(menu) == 0) return false;
    const group = c.g_simple_action_group_new().?;
    defer c.g_object_unref(group);
    const model = c.g_menu_new().?;
    defer c.g_object_unref(model);
    addItems(group, model, c.webkit_context_menu_get_items(menu));
    addTranslate(group, model, selection);
    addContacts(group, model, editable);
    addNearby(group, model, if (editable == null) uri else null);
    c.gtk_widget_insert_action_group(w, "ctx", @ptrCast(group));
    const popover = c.gtk_popover_menu_new_from_model(@ptrCast(@alignCast(model)));
    const area: c.GdkRectangle = .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &area);
    c.gtk_popover_set_has_arrow(@ptrCast(popover), 0);
    c.gtk_widget_set_halign(popover, c.GTK_ALIGN_START);
    c.gtk_widget_set_parent(popover, w);
    _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&contextClosed), null, null, c.G_CONNECT_AFTER);
    c.gtk_popover_popup(@ptrCast(popover));
    return true;
}

var shown: ?*c.GHashTable = null;

fn notificationClicked(_: ?*c.GSimpleAction, param: ?*c.GVariant, _: c.gpointer) callconv(.c) void {
    const table = shown orelse return;
    const id = c.g_variant_get_uint64(param);
    const n = c.g_hash_table_lookup(table, &id) orelse return;
    c.webkit_notification_clicked(@ptrCast(@alignCast(n)));
}

fn notificationClosed(n: ?*c.WebKitNotification, _: c.gpointer) callconv(.c) void {
    const id = c.webkit_notification_get_id(n);
    const name = c.g_strdup_printf("fotone-%" ++ c.G_GUINT64_FORMAT, id);
    defer c.g_free(name);
    if (c.g_application_get_default()) |app| c.g_application_withdraw_notification(app, name);
    if (shown) |table| _ = c.g_hash_table_remove(table, &id);
}

fn ensureAction(app: *c.GApplication) void {
    if (c.g_action_map_lookup_action(@ptrCast(app), "fotone-notification") != null) return;
    const action = c.g_simple_action_new("fotone-notification", c.g_variant_type_checked_("t"));
    defer c.g_object_unref(action);
    _ = c.g_signal_connect_data(action, "activate", @ptrCast(&notificationClicked), null, null, 0);
    c.g_action_map_add_action(@ptrCast(app), @ptrCast(action));
}

pub fn showNotification(_: ?*c.WebKitWebView, n: ?*c.WebKitNotification, _: c.gpointer) callconv(.c) c.gboolean {
    const note = n orelse return 0;
    const app = c.g_application_get_default() orelse return 0;
    ensureAction(app);
    if (shown == null) shown = c.g_hash_table_new_full(c.g_int64_hash, c.g_int64_equal, c.g_free, c.g_object_unref);
    const id = c.webkit_notification_get_id(note);
    const key: *u64 = @ptrCast(@alignCast(c.g_malloc(@sizeOf(u64))));
    key.* = id;
    _ = c.g_hash_table_replace(shown, key, c.g_object_ref(note));
    _ = c.g_signal_connect_data(note, "closed", @ptrCast(&notificationClosed), null, null, 0);
    const gn = c.g_notification_new(c.webkit_notification_get_title(note));
    defer c.g_object_unref(gn);
    c.g_notification_set_body(gn, c.webkit_notification_get_body(note));
    c.g_notification_set_default_action_and_target_value(gn, "app.fotone-notification", c.g_variant_new_uint64(id));
    const name = c.g_strdup_printf("fotone-%" ++ c.G_GUINT64_FORMAT, id);
    defer c.g_free(name);
    c.g_application_send_notification(app, name, gn);
    return 1;
}

var granted: ?*c.GHashTable = null;

fn isA(o: anytype, t: c.GType) bool {
    return c.g_type_check_instance_is_a(@ptrCast(@alignCast(o)), t) != 0;
}

fn permissionText(r: *c.WebKitPermissionRequest) ?[*:0]const u8 {
    if (isA(r, c.webkit_user_media_permission_request_get_type())) {
        const m: *c.WebKitUserMediaPermissionRequest = @ptrCast(@alignCast(r));
        if (c.webkit_user_media_permission_is_for_display_device(m) != 0) return "%s wants to share your screen";
        const audio = c.webkit_user_media_permission_is_for_audio_device(m) != 0;
        const video = c.webkit_user_media_permission_is_for_video_device(m) != 0;
        if (audio and video) return "%s wants to use your camera and microphone";
        if (video) return "%s wants to use your camera";
        return "%s wants to use your microphone";
    }
    if (isA(r, c.webkit_geolocation_permission_request_get_type())) return "%s wants to know your location";
    if (isA(r, c.webkit_notification_permission_request_get_type())) return "%s wants to show notifications";
    if (isA(r, c.webkit_pointer_lock_permission_request_get_type())) return "%s wants to hide and lock the pointer";
    if (isA(r, c.webkit_device_info_permission_request_get_type())) return "%s wants to list your cameras and microphones";
    if (isA(r, c.webkit_website_data_access_permission_request_get_type())) return "%s wants to use its cookies on this site";
    return null;
}

fn permissionKey(web: ?*c.WebKitWebView, r: *c.WebKitPermissionRequest) [*c]u8 {
    const uri = c.webkit_web_view_get_uri(web);
    const parsed = if (uri != null) c.g_uri_parse(uri, c.G_URI_FLAGS_NONE, null) else null;
    defer if (parsed) |p| c.g_uri_unref(p);
    const host = if (parsed) |p| c.g_uri_get_host(p) else null;
    return c.g_strdup_printf("%s %s", if (host != null) host else @as([*c]const u8, ""), c.g_type_name(c.G_TYPE_FROM_INSTANCE(r)));
}

fn storedEntries(r: *c.WebKitPermissionRequest, out: *[2]perms.Entry) []const perms.Entry {
    if (isA(r, c.webkit_user_media_permission_request_get_type())) {
        const m: *c.WebKitUserMediaPermissionRequest = @ptrCast(@alignCast(r));
        if (c.webkit_user_media_permission_is_for_display_device(m) != 0) return out[0..0];
        var n: usize = 0;
        if (c.webkit_user_media_permission_is_for_video_device(m) != 0) {
            out[n] = perms.CAMERA;
            n += 1;
        }
        if (c.webkit_user_media_permission_is_for_audio_device(m) != 0) {
            out[n] = perms.MICROPHONE;
            n += 1;
        }
        return out[0..n];
    }
    if (isA(r, c.webkit_geolocation_permission_request_get_type())) {
        out[0] = perms.LOCATION;
        return out[0..1];
    }
    if (isA(r, c.webkit_notification_permission_request_get_type())) {
        out[0] = perms.NOTIFICATIONS;
        return out[0..1];
    }
    return out[0..0];
}

fn storedDecision(app: [*:0]const u8, entries: []const perms.Entry) ?bool {
    if (entries.len == 0) return null;
    var all = true;
    for (entries) |e| {
        const v = perms.lookup(e, app) orelse {
            all = false;
            continue;
        };
        if (!v) return false;
    }
    return if (all) true else null;
}

const Ask = struct {
    request: *c.WebKitPermissionRequest,
    key: [*c]u8,
    app: [*c]u8 = null,
    entries: [2]perms.Entry = undefined,
    n: usize = 0,

    fn remember(a: *Ask, allowed: bool) void {
        const app = a.app orelse return;
        for (a.entries[0..a.n]) |e| perms.store(e, app, allowed);
        c.g_free(app);
    }
};

fn permissionChosen(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const a: *Ask = @ptrCast(@alignCast(data));
    defer c.g_free(a);
    defer c.g_object_unref(a.request);
    const i = c.gtk_alert_dialog_choose_finish(@ptrCast(@alignCast(src)), res, null);
    if (i >= 0) a.remember(i == 1) else if (a.app) |app| c.g_free(app);
    if (i != 1) {
        c.g_free(a.key);
        return c.webkit_permission_request_deny(a.request);
    }
    if (granted == null) granted = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, null);
    _ = c.g_hash_table_add(granted, a.key);
    c.webkit_permission_request_allow(a.request);
}

pub fn permissionRequest(web: ?*c.WebKitWebView, r: ?*c.WebKitPermissionRequest, data: c.gpointer) callconv(.c) c.gboolean {
    const w: *c.GtkWidget = @ptrCast(@alignCast(data));
    const req = r orelse return 0;
    if (isA(req, c.webkit_media_key_system_permission_request_get_type())) {
        c.webkit_permission_request_allow(req);
        return 1;
    }
    const text = permissionText(req) orelse return 0;
    var stored: [2]perms.Entry = undefined;
    const entries = storedEntries(req, &stored);
    const app = perms.appOf(web);
    if (app) |id| if (storedDecision(id, entries)) |allowed| {
        if (allowed) c.webkit_permission_request_allow(req) else c.webkit_permission_request_deny(req);
        return 1;
    };
    const key = permissionKey(web, req);
    if (granted != null and c.g_hash_table_contains(granted, key) != 0) {
        c.g_free(key);
        c.webkit_permission_request_allow(req);
        return 1;
    }
    const host = std.mem.span(@as([*:0]u8, @ptrCast(key)));
    const space = std.mem.indexOfScalar(u8, host, ' ') orelse host.len;
    const site = c.g_strndup(key, space);
    defer c.g_free(site);
    const message = c.g_strdup_printf(c.g_dgettext("fotone", text), site);
    defer c.g_free(message);
    const d = c.gtk_alert_dialog_new("%s", message);
    defer c.g_object_unref(d);
    const labels = [_:null]?[*:0]const u8{ c.g_dgettext("fotone", "_Deny"), c.g_dgettext("fotone", "_Allow") };
    c.gtk_alert_dialog_set_buttons(d, @ptrCast(&labels));
    c.gtk_alert_dialog_set_cancel_button(d, 0);
    c.gtk_alert_dialog_set_default_button(d, 1);
    const a: *Ask = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Ask))));
    a.* = .{ .request = @ptrCast(@alignCast(c.g_object_ref(req))), .key = key };
    if (app) |id| if (entries.len > 0) {
        a.app = c.g_strdup(id);
        a.n = entries.len;
        @memcpy(a.entries[0..entries.len], entries);
    };
    c.gtk_alert_dialog_choose(d, window(w), null, permissionChosen, a);
    return 1;
}
