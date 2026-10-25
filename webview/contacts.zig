const std = @import("std");
const c = @import("c.zig").c;

pub const MAX = 24;

const FILL =
    \\const rules = [["given-name", /first|given|fname|nome/], ["family-name", /last|family|surname|lname|cognome/],
    \\  ["email", /mail/], ["tel", /phone|tel|mobile|cell/], ["organization", /company|organi[sz]ation|org\b/],
    \\  ["street-address", /street|address|addr|indirizzo/], ["address-level2", /city|town|citta/],
    \\  ["postal-code", /zip|postal|postcode|\bcap\b/], ["country-name", /country|paese|nazione/], ["name", /name/]];
    \\const pick = (f) => {
    \\  const a = (f.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/).pop();
    \\  if (card[a]) return a;
    \\  const t = (f.type || "").toLowerCase();
    \\  if (t === "email" || t === "tel") return t;
    \\  const n = ((f.name || "") + " " + (f.id || "") + " " + (f.placeholder || "")).toLowerCase();
    \\  for (const [k, re] of rules) if (re.test(n)) return k;
    \\  return null;
    \\};
    \\const el = document.activeElement;
    \\const root = (el && (el.form || el.closest("form"))) || document;
    \\let filled = 0;
    \\for (const f of root.querySelectorAll("input, textarea")) {
    \\  if (f.value || f.disabled || f.readOnly || ["hidden", "password", "checkbox", "radio", "submit", "button"].includes(f.type)) continue;
    \\  const k = pick(f);
    \\  if (!k || !card[k]) continue;
    \\  f.value = card[k];
    \\  f.dispatchEvent(new Event("input", { bubbles: true }));
    \\  f.dispatchEvent(new Event("change", { bubbles: true }));
    \\  filled++;
    \\}
    \\return filled;
;

pub const Field = enum { name, given, family, email, tel, org, street, city, postal, country };

const KEYS = [_][*:0]const u8{ "name", "given-name", "family-name", "email", "tel", "organization", "street-address", "address-level2", "postal-code", "country-name" };

pub const Card = struct {
    at: [KEYS.len][2]u16 = [_][2]u16{.{ 0, 0 }} ** KEYS.len,
    buf: [2048]u8 = undefined,
    used: usize = 0,

    fn put(card: *Card, f: Field, raw: []const u8) void {
        if (card.at[@intFromEnum(f)][1] > 0) return;
        const start = card.used;
        var i: usize = 0;
        while (i < raw.len and card.used < card.buf.len) : (i += 1) {
            var ch = raw[i];
            if (ch == '\\' and i + 1 < raw.len) {
                i += 1;
                ch = if (raw[i] == 'n' or raw[i] == 'N') ' ' else raw[i];
            }
            card.buf[card.used] = ch;
            card.used += 1;
        }
        var a = start;
        var b = card.used;
        while (a < b and card.buf[a] == ' ') a += 1;
        while (b > a and card.buf[b - 1] == ' ') b -= 1;
        card.at[@intFromEnum(f)] = .{ @intCast(a), @intCast(b - a) };
    }

    pub fn get(card: *const Card, f: Field) []const u8 {
        const r = card.at[@intFromEnum(f)];
        return card.buf[r[0]..][0..r[1]];
    }

    pub fn variant(card: *const Card) ?*c.GVariant {
        const b = c.g_variant_builder_new(c.g_variant_type_checked_("a{ss}"));
        defer c.g_variant_builder_unref(b);
        for (KEYS, 0..) |k, i| {
            const s = card.get(@enumFromInt(i));
            if (s.len == 0) continue;
            const z = c.g_strndup(s.ptr, s.len);
            defer c.g_free(z);
            c.g_variant_builder_add(b, "{ss}", k, z);
        }
        return c.g_variant_builder_end(b);
    }
};

fn component(value: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var start: usize = 0;
    var k: usize = 0;
    while (k <= value.len) : (k += 1) {
        const end = k == value.len;
        if (!end and value[k] == '\\') {
            k += 1;
            continue;
        }
        if (end or value[k] == ';') {
            if (i == n) return value[start..k];
            i += 1;
            start = k + 1;
        }
    }
    return "";
}

fn property(card: *Card, name: []const u8, value: []const u8) void {
    if (std.ascii.eqlIgnoreCase(name, "FN")) card.put(.name, value);
    if (std.ascii.eqlIgnoreCase(name, "EMAIL")) card.put(.email, value);
    if (std.ascii.eqlIgnoreCase(name, "TEL")) card.put(.tel, value);
    if (std.ascii.eqlIgnoreCase(name, "ORG")) card.put(.org, component(value, 0));
    if (std.ascii.eqlIgnoreCase(name, "N")) {
        card.put(.family, component(value, 0));
        card.put(.given, component(value, 1));
    }
    if (std.ascii.eqlIgnoreCase(name, "ADR")) {
        card.put(.street, component(value, 2));
        card.put(.city, component(value, 3));
        card.put(.postal, component(value, 5));
        card.put(.country, component(value, 6));
    }
}

pub fn parse(card: *Card, vcard: []const u8) void {
    var line: [1024]u8 = undefined;
    var len: usize = 0;
    var it = std.mem.splitScalar(u8, vcard, '\n');
    while (true) {
        const next = it.next();
        const raw = if (next) |r| std.mem.trimEnd(u8, r, "\r") else "";
        if (next != null and raw.len > 0 and (raw[0] == ' ' or raw[0] == '\t')) {
            const rest = raw[1..];
            const n = @min(rest.len, line.len - len);
            @memcpy(line[len..][0..n], rest[0..n]);
            len += n;
            continue;
        }
        if (len > 0) {
            const l = line[0..len];
            if (std.mem.indexOfScalar(u8, l, ':')) |colon| {
                var key = l[0..colon];
                if (std.mem.indexOfScalar(u8, key, ';')) |semi| key = key[0..semi];
                if (std.mem.lastIndexOfScalar(u8, key, '.')) |dot| key = key[dot + 1 ..];
                property(card, key, l[colon + 1 ..]);
            }
        }
        if (next == null) break;
        const n = @min(raw.len, line.len);
        @memcpy(line[0..n], raw[0..n]);
        len = n;
    }
    if (card.get(.name).len == 0 and (card.get(.given).len > 0 or card.get(.family).len > 0)) {
        var tmp: [256]u8 = undefined;
        const full = std.fmt.bufPrint(&tmp, "{s} {s}", .{ card.get(.given), card.get(.family) }) catch return;
        card.put(.name, full);
    }
}

fn items(json: []const u8, out: []Card, n: *usize) void {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const list = parsed.value.object.get("items") orelse return;
    if (list != .array) return;
    for (list.array.items) |item| {
        if (n.* == out.len) return;
        if (item != .object) continue;
        if (item.object.get("state")) |s| if (s == .string and std.mem.eql(u8, s.string, "deleted")) continue;
        const data = item.object.get("data") orelse continue;
        if (data != .string) continue;
        out[n.*] = .{};
        parse(&out[n.*], data.string);
        if (out[n.*].get(.name).len > 0) n.* += 1;
    }
}

fn byName(_: void, a: Card, b: Card) bool {
    return std.ascii.lessThanIgnoreCase(a.get(.name), b.get(.name));
}

pub fn load(out: []Card) usize {
    var n: usize = 0;
    const base = c.g_build_filename(c.g_get_user_data_dir(), "singularity", "accounts", @as([*c]const u8, null));
    defer c.g_free(base);
    const accounts = c.g_dir_open(base, 0, null) orelse return 0;
    defer c.g_dir_close(accounts);
    while (c.g_dir_read_name(accounts)) |acct| {
        const dir = c.g_build_filename(base, acct, "contacts", @as([*c]const u8, null));
        defer c.g_free(dir);
        const files = c.g_dir_open(dir, 0, null) orelse continue;
        defer c.g_dir_close(files);
        while (c.g_dir_read_name(files)) |file| {
            if (c.g_str_has_suffix(file, ".json") == 0 or c.g_str_equal(file, "collections.json") != 0) continue;
            const path = c.g_build_filename(dir, file, @as([*c]const u8, null));
            defer c.g_free(path);
            var data: [*c]u8 = null;
            var size: usize = 0;
            if (c.g_file_get_contents(path, &data, &size, null) == 0) continue;
            defer c.g_free(data);
            items(data[0..size], out, &n);
        }
    }
    std.mem.sort(Card, out[0..n], {}, byName);
    return n;
}

pub fn fill(web: *c.WebKitWebView, card: *c.GVariant) void {
    const args = c.g_variant_builder_new(c.g_variant_type_checked_("a{sv}"));
    defer c.g_variant_builder_unref(args);
    c.g_variant_builder_add(args, "{sv}", "card", card);
    c.webkit_web_view_call_async_javascript_function(web, FILL, -1, c.g_variant_builder_end(args), "fotone-contacts", null, null, null, null);
}

test "vcards give the fields forms ask for" {
    var card: Card = .{};
    parse(&card, "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Rossi;Anna;;;\r\nitem1.EMAIL;TYPE=INTERNET:anna@example.org\r\nTEL;TYPE=CELL:+39 333 1234\r\nORG:Esempio\\, Srl;Ricerca\r\nADR;TYPE=HOME:;;Via Roma 1;Milano;MI;20100;Ital\r\n ia\r\nEND:VCARD\r\n");
    try std.testing.expectEqualStrings("Anna Rossi", card.get(.name));
    try std.testing.expectEqualStrings("Anna", card.get(.given));
    try std.testing.expectEqualStrings("Rossi", card.get(.family));
    try std.testing.expectEqualStrings("anna@example.org", card.get(.email));
    try std.testing.expectEqualStrings("+39 333 1234", card.get(.tel));
    try std.testing.expectEqualStrings("Esempio, Srl", card.get(.org));
    try std.testing.expectEqualStrings("Via Roma 1", card.get(.street));
    try std.testing.expectEqualStrings("Milano", card.get(.city));
    try std.testing.expectEqualStrings("20100", card.get(.postal));
    try std.testing.expectEqualStrings("Italia", card.get(.country));
}

test "mirror files list live contacts by name" {
    var out: [4]Card = undefined;
    var n: usize = 0;
    items("{\"items\":[{\"data\":\"BEGIN:VCARD\\nFN:Zeno\\nEND:VCARD\",\"state\":\"synced\"},{\"data\":\"BEGIN:VCARD\\nFN:Gone\\nEND:VCARD\",\"state\":\"deleted\"},{\"data\":\"BEGIN:VCARD\\nFN:Bea\\nEND:VCARD\"}]}", &out, &n);
    try std.testing.expectEqual(@as(usize, 2), n);
    std.mem.sort(Card, out[0..n], {}, byName);
    try std.testing.expectEqualStrings("Bea", out[0].get(.name));
}
