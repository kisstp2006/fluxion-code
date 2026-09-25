// SPDX-License-Identifier: BSD-2-Clause

//! The colours a text writes, and the ways a language writes them.
//!
//! A language lists its `Form`s - `color(0.2, 0.4, 0.8)`, `"#3366CC"`,
//! `hsv(220, 0.75, 0.8)`, `color("royalblue")` - as data, and `find` reads
//! every colour so written out of a text, with the form it is in. `write`
//! writes a colour back in any of them, which is what the view's picker does
//! as it is dragged, and what its buttons do to turn one form into another.
//!
//! ```zig
//! const flux_colors = [_]colors.Form{
//!     .{ .channels = .{ .call = "color" } },
//!     .{ .hex = .{ .call = "color" } },
//!     .{ .hsv = .{ .call = "hsv" } },
//! };
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ui_lib = @import("fluxion_ui");
const language = @import("language.zig");

const Color = ui_lib.Color;

pub const Form = union(enum) {
    /// `"#RRGGBB"`, `"#RRGGBBAA"` or `"#RGB"` in a string - inside a call of
    /// `call`'s name, as `color("#3366CC")`, or on its own, as JSON has it.
    hex: Hex,
    /// `call(r, g, b[, a])`: numbers from nought to `scale`.
    channels: Channels,
    /// `call(h, s, v[, a])`: the hue in degrees, the rest from nought to one.
    hsv: Call,
    /// `call("name")`: a colour by one of `names`.
    named: Named,

    pub const Hex = struct {
        call: ?[]const u8 = null,
    };

    pub const Channels = struct {
        call: []const u8,
        /// What a full channel is: 1, or 255.
        scale: f32 = 1,
        /// How many numbers it takes: 3 with no alpha, 4 with one, or 3 to 4.
        least: u8 = 3,
        most: u8 = 4,
        /// Every number from nought to one, or it is not a colour: what a
        /// shader's `vec4` is when it is not a place.
        unit_only: bool = false,
    };

    pub const Call = struct {
        call: []const u8,
    };

    pub const Named = struct {
        call: []const u8,
        names: []const Name,
    };

    /// What a button offering the form says.
    pub fn label(self: Form, buffer: []u8) []const u8 {
        return switch (self) {
            .hex => |h| if (h.call) |call| std.fmt.bufPrint(buffer, "{s}(\"#hex\")", .{call}) catch "hex" else "\"#hex\"",
            .channels => |c| std.fmt.bufPrint(buffer, "{s}({s})", .{ c.call, if (c.most == 3) "r, g, b" else "r, g, b, a" }) catch c.call,
            .hsv => |c| std.fmt.bufPrint(buffer, "{s}(h, s, v)", .{c.call}) catch c.call,
            .named => |n| std.fmt.bufPrint(buffer, "{s}(\"name\")", .{n.call}) catch n.call,
        };
    }
};

/// A colour by name: `"royalblue"`, 0x4169E1.
pub const Name = struct {
    name: []const u8,
    rgb: u24,
};

/// A colour found in a text: where it is written, what it is, and which of
/// the language's forms it is written in.
pub const Found = struct {
    start: u32,
    end: u32,
    color: Color,
    form: u8,
};

/// Every colour written in `text` in one of `forms`, in order, none inside a
/// comment - and none inside a string but a form's own. `tokens` are the
/// text's colours, to tell comments and strings by.
pub fn find(arena: Allocator, text: []const u8, forms: []const Form, tokens: []const language.Token) Allocator.Error![]const Found {
    if (forms.len == 0) return &.{};
    var out: std.ArrayList(Found) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        const found = foundAt(text, at, forms, tokens);
        if (found) |f| {
            try out.append(arena, f);
            at = f.end;
        } else at += 1;
    }
    return out.items;
}

fn foundAt(text: []const u8, at: usize, forms: []const Form, tokens: []const language.Token) ?Found {
    const style = styleAt(tokens, at);
    if (style == .comment or style == .doc_comment) return null;
    for (forms, 0..) |form, i| {
        const read = switch (form) {
            .hex => |h| if (h.call) |call| readCall(text, at, call, style, {}, readHexArg) else readHexString(text, at),
            .channels => |c| readCall(text, at, c.call, style, c, readChannelArgs),
            .hsv => |c| readCall(text, at, c.call, style, {}, readHsvArgs),
            .named => |n| readCall(text, at, n.call, style, n.names, readNamedArg),
        } orelse continue;
        return .{ .start = @intCast(at), .end = @intCast(read.end), .color = read.color, .form = @intCast(i) };
    }
    return null;
}

fn styleAt(tokens: []const language.Token, at: usize) language.Style {
    var lo: usize = 0;
    var hi = tokens.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const t = tokens[mid];
        if (t.start + t.len <= at) lo = mid + 1 else if (t.start > at) hi = mid else return t.style;
    }
    return .plain;
}

const Read = struct { end: usize, color: Color };

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `call(` at `at`, its name not the end of a longer one, and not in a
/// string; what `args` reads between the brackets, and the closing one.
fn readCall(
    text: []const u8,
    at: usize,
    call: []const u8,
    style: language.Style,
    context: anytype,
    comptime args: fn (@TypeOf(context), []const u8, usize) ?Read,
) ?Read {
    if (style == .string) return null;
    if (!std.mem.startsWith(u8, text[at..], call)) return null;
    if (at > 0 and (isWord(text[at - 1]) or text[at - 1] == '.')) return null;
    var i = at + call.len;
    i = skipSpace(text, i);
    if (i >= text.len or text[i] != '(') return null;
    const inside = args(context, text, i + 1) orelse return null;
    const close = skipSpace(text, inside.end);
    if (close >= text.len or text[close] != ')') return null;
    return .{ .end = close + 1, .color = inside.color };
}

fn skipSpace(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

/// A number: a sign, digits, a point and more digits.
fn readNumber(text: []const u8, from: usize) ?struct { end: usize, value: f32 } {
    var i = from;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) i += 1;
    const digits = i;
    while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.')) i += 1;
    if (i == digits) return null;
    // A number followed by a letter is a name or a suffix of a kind this
    // does not read.
    if (i < text.len and (std.ascii.isAlphabetic(text[i]) or text[i] == '_')) return null;
    const value = std.fmt.parseFloat(f32, text[from..i]) catch return null;
    return .{ .end = i, .value = value };
}

/// Up to four numbers apart by commas, and how many.
fn readNumbers(text: []const u8, from: usize, into: *[4]f32) ?struct { end: usize, count: u8 } {
    var i = skipSpace(text, from);
    var count: u8 = 0;
    while (true) {
        if (count == 4) return null;
        const n = readNumber(text, i) orelse return null;
        into[count] = n.value;
        count += 1;
        i = skipSpace(text, n.end);
        if (i < text.len and text[i] == ',') {
            i = skipSpace(text, i + 1);
            continue;
        }
        return .{ .end = i, .count = count };
    }
}

fn readChannelArgs(wanted: Form.Channels, text: []const u8, from: usize) ?Read {
    var n: [4]f32 = .{ 0, 0, 0, 0 };
    const got = readNumbers(text, from, &n) orelse return null;
    if (got.count < wanted.least or got.count > wanted.most) return null;
    for (n[0..got.count]) |v| {
        if (v < 0 or v > wanted.scale) return null;
        if (wanted.unit_only and v > 1) return null;
    }
    const a = if (got.count == 4) n[3] / wanted.scale else 1;
    return .{ .end = got.end, .color = .rgba(n[0] / wanted.scale, n[1] / wanted.scale, n[2] / wanted.scale, a) };
}

fn readHsvArgs(_: void, text: []const u8, from: usize) ?Read {
    var n: [4]f32 = .{ 0, 0, 0, 1 };
    const got = readNumbers(text, from, &n) orelse return null;
    if (got.count < 3) return null;
    if (n[1] < 0 or n[1] > 1 or n[2] < 0 or n[2] > 1 or n[3] < 0 or n[3] > 1) return null;
    return .{ .end = got.end, .color = Color.hsv(n[0] / 360, n[1], n[2], n[3]) };
}

/// A quoted string at `from` and what is in it, the quotes not.
fn readString(text: []const u8, from: usize) ?struct { end: usize, inside: []const u8 } {
    const i = skipSpace(text, from);
    if (i >= text.len or (text[i] != '"' and text[i] != '\'')) return null;
    const quote = text[i];
    const close = std.mem.indexOfScalarPos(u8, text, i + 1, quote) orelse return null;
    if (std.mem.indexOfScalar(u8, text[i + 1 .. close], '\n') != null) return null;
    return .{ .end = close + 1, .inside = text[i + 1 .. close] };
}

fn readHexArg(_: void, text: []const u8, from: usize) ?Read {
    const s = readString(text, from) orelse return null;
    if (s.inside.len == 0 or s.inside[0] != '#') return null;
    return .{ .end = s.end, .color = ui_lib.ColorPicker.parseHex(s.inside) orelse return null };
}

/// `"#3366CC"`, starting a string of its own.
fn readHexString(text: []const u8, at: usize) ?Read {
    if (text[at] != '"' and text[at] != '\'') return null;
    if (at > 0 and (text[at - 1] == '\\' or isWord(text[at - 1]))) return null;
    return readHexArg({}, text, at);
}

fn readNamedArg(names: []const Name, text: []const u8, from: usize) ?Read {
    const s = readString(text, from) orelse return null;
    const found = named(names, s.inside) orelse return null;
    return .{ .end = s.end, .color = .hex(found.rgb) };
}

/// The name in `names` spelt so, in any case.
pub fn named(names: []const Name, name: []const u8) ?Name {
    for (names) |n| if (std.ascii.eqlIgnoreCase(n.name, name)) return n;
    return null;
}

/// The name of exactly this colour, if it has one: what `write` gives a
/// named form, and nothing for a colour between names or not opaque.
pub fn nameOf(names: []const Name, c: Color) ?[]const u8 {
    if (byte(c.a) != 255) return null;
    const rgb: u24 = (@as(u24, byte(c.r)) << 16) | (@as(u24, byte(c.g)) << 8) | byte(c.b);
    for (names) |n| if (n.rgb == rgb) return n.name;
    return null;
}

fn byte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// `c` written as `form` writes a colour, in `buffer`, or null for a form
/// that cannot say it - a name for a colour that has none. `was` is the
/// text it replaces: a count of numbers and a quote are kept as they were.
pub fn write(buffer: []u8, form: Form, c: Color, was: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    const quote: u8 = if (std.mem.indexOfScalar(u8, was, '\'') != null and std.mem.indexOfScalar(u8, was, '"') == null) '\'' else '"';
    switch (form) {
        .hex => |h| {
            var hex: [16]u8 = undefined;
            const digits = ui_lib.ColorPicker.hexOf(&hex, c);
            if (h.call) |call| w.print("{s}({c}{s}{c})", .{ call, quote, digits, quote }) catch return null else w.print("{c}{s}{c}", .{ quote, digits, quote }) catch return null;
        },
        .channels => |ch| {
            const with_alpha = ch.least == 4 or (ch.most == 4 and (byte(c.a) != 255 or countNumbers(was) == 4));
            w.print("{s}(", .{ch.call}) catch return null;
            const values = [4]f32{ c.r, c.g, c.b, c.a };
            const n: usize = if (with_alpha) 4 else 3;
            for (values[0..n], 0..) |v, i| {
                if (i > 0) w.writeAll(", ") catch return null;
                number(&w, v, ch.scale) catch return null;
            }
            w.writeAll(")") catch return null;
        },
        .hsv => |call| {
            const hsv = c.toHsv();
            w.print("{s}(", .{call.call}) catch return null;
            number(&w, hsv[0], 360) catch return null;
            w.writeAll(", ") catch return null;
            number(&w, hsv[1], 1) catch return null;
            w.writeAll(", ") catch return null;
            number(&w, hsv[2], 1) catch return null;
            if (byte(c.a) != 255) {
                w.writeAll(", ") catch return null;
                number(&w, c.a, 1) catch return null;
            }
            w.writeAll(")") catch return null;
        },
        .named => |n| {
            const name = nameOf(n.names, c) orelse return null;
            w.print("{s}({c}{s}{c})", .{ n.call, quote, name, quote }) catch return null;
        },
    }
    return w.buffered();
}

fn countNumbers(was: []const u8) usize {
    const open = std.mem.indexOfScalar(u8, was, '(') orelse return 0;
    var n: [4]f32 = undefined;
    const got = readNumbers(was, open + 1, &n) orelse return 0;
    return got.count;
}

/// A channel from nought to one as `scale` writes it: a whole number out
/// of 255 or of 360, and otherwise at most three places, with a point so a
/// language that tells a float by it takes it as one.
fn number(w: *std.Io.Writer, v: f32, scale: f32) !void {
    if (scale > 1) {
        try w.print("{d}", .{@round(std.math.clamp(v, 0, 1) * scale)});
        return;
    }
    const rounded = @round(std.math.clamp(v, 0, 1) * 1000) / 1000;
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{rounded});
    try w.writeAll(text);
    if (std.mem.indexOfScalar(u8, text, '.') == null) try w.writeAll(".0");
}

// ---------------------------------------------------------------------------
// Tests

const test_names = [_]Name{ .{ .name = "red", .rgb = 0xFF0000 }, .{ .name = "royalblue", .rgb = 0x4169E1 } };
const flux_forms = [_]Form{
    .{ .channels = .{ .call = "color" } },
    .{ .hex = .{ .call = "color" } },
    .{ .hsv = .{ .call = "hsv" } },
    .{ .named = .{ .call = "color", .names = &test_names } },
};

test "every colour a text writes is found, in the form it is written in, and not in a comment" {
    const text =
        \\var a = color(0.2, 0.4, 0.8);
        \\var b = color("#FF8000");
        \\var c = hsv(120, 1, 0.5, 0.5);
        \\// color(1, 0, 0) in a comment
        \\var d = color("royalblue");
        \\var e = mycolor(1, 1, 1);
        \\var f = color(3, 0, 0);
    ;
    const comment_start: u32 = @intCast(std.mem.indexOf(u8, text, "//").?);
    const tokens = [_]language.Token{.{ .start = comment_start, .len = 30, .style = .comment }};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try find(arena.allocator(), text, &flux_forms, &tokens);
    try testing.expectEqual(@as(usize, 4), found.len);
    try testing.expectEqualStrings("color(0.2, 0.4, 0.8)", text[found[0].start..found[0].end]);
    try testing.expectEqual(@as(u8, 0), found[0].form);
    try testing.expectApproxEqAbs(@as(f32, 0.4), found[0].color.g, 0.001);
    try testing.expectEqual(@as(u8, 1), found[1].form);
    try testing.expectApproxEqAbs(@as(f32, 0x80.0 / 255.0), found[1].color.g, 0.001);
    try testing.expectEqual(@as(u8, 2), found[2].form);
    try testing.expectApproxEqAbs(@as(f32, 0.5), found[2].color.g, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), found[2].color.a, 0.001);
    try testing.expectEqual(@as(u8, 3), found[3].form);
    try testing.expectApproxEqAbs(@as(f32, 0xE1.0 / 255.0), found[3].color.b, 0.001);
}

test "a colour is written back in any form, keeping how many numbers and which quote it had" {
    var buffer: [64]u8 = undefined;
    const blue: Color = .hex(0x3366CC);
    try testing.expectEqualStrings("color(0.2, 0.4, 0.8)", write(&buffer, flux_forms[0], blue, "color(1, 1, 1)").?);
    try testing.expectEqualStrings("color(0.2, 0.4, 0.8, 1.0)", write(&buffer, flux_forms[0], blue, "color(1, 1, 1, 1)").?);
    try testing.expectEqualStrings("color(0.2, 0.4, 0.8, 0.5)", write(&buffer, flux_forms[0], blue.withAlpha(0.5), "color(1, 1, 1)").?);
    try testing.expectEqualStrings("color(\"#3366CC\")", write(&buffer, flux_forms[1], blue, "").?);
    try testing.expectEqualStrings("color('#3366CC')", write(&buffer, flux_forms[1], blue, "color('#fff')").?);
    try testing.expectEqualStrings("hsv(220, 0.75, 0.8)", write(&buffer, flux_forms[2], blue, "").?);
    try testing.expect(write(&buffer, flux_forms[3], blue, "") == null);
    try testing.expectEqualStrings("color(\"red\")", write(&buffer, flux_forms[3], .hex(0xFF0000), "").?);

    // A shader's vector: only one between nought and one is a colour.
    const vec4: Form = .{ .channels = .{ .call = "vec4", .least = 4, .most = 4, .unit_only = true } };
    try testing.expectEqualStrings("vec4(1.0, 0.5, 0.0, 1.0)", write(&buffer, vec4, .rgba(1, 0.5, 0, 1), "").?);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try find(arena.allocator(), "vec4(1.0, 0.5, 0.0, 1.0) vec4(2.0, 0.0, 0.0, 1.0)", &.{vec4}, &.{});
    try testing.expectEqual(@as(usize, 1), found.len);

    // A JSON file's hex, a string of its own.
    const json_hex: Form = .{ .hex = .{} };
    const in_json = try find(arena.allocator(), "{ \"color\": \"#FF0000\", \"name\": \"#nope\" }", &.{json_hex}, &.{});
    try testing.expectEqual(@as(usize, 1), in_json.len);
    try testing.expectEqualStrings("\"#00FF00\"", write(&buffer, json_hex, .hex(0x00FF00), "\"#FF0000\"").?);
}
