// SPDX-License-Identifier: BSD-2-Clause

//! A `Document` drawn with fluxion-ui: one row a line, and only the lines in
//! view. A row is the line's text in runs, each coloured by its token's
//! style and each after the last as text is set - a tab as room to the next
//! stop - and the line numbers go over the rows so that a line scrolled
//! sideways passes under them. Over it all float the selection, the places
//! the find bar found, the lines under mistakes, the caret, the scrollbar,
//! and the completion list and the tooltips. The find bar goes above.
//!
//! Every place is measured through the document's `Metrics`, so the font can
//! be any: a `Ruler` measures with the interface's own measurer.

const std = @import("std");
const ui_lib = @import("fluxion_ui");
const Document = @import("Document.zig");
const Theme = @import("Theme.zig");
const search = @import("search.zig");
const colors = @import("colors.zig");

const Ui = ui_lib.Ui;
const Color = ui_lib.Color;

const View = @This();

/// What the view's elements are called: to find the view with `boxOf`, and
/// to tell the view's popups from the rest of an interface.
ids: Ids = .{},
theme: *const Theme = &Theme.dark,
/// The interface's font for code - the rows, the line numbers, completions,
/// signatures, a hover's declaration - as an index into its measurer's
/// table: a monospaced one, when the interface has one. `Ruler.style` wants
/// the same, so that what is measured is what is drawn.
font: u16 = 0,
/// And for prose: the docs under completions, signatures and hovers, and
/// the find bar.
prose_font: u16 = 0,
/// The minimap's texture, as a number in the table the interface's renderer
/// was given - the host makes it from `minimapPixels` - or null for none.
minimap_texture: ?u32 = null,

pub const Ids = struct {
    code: []const u8 = "code",
    completion: []const u8 = "code-completion",
    completion_doc: []const u8 = "code-completion-doc",
    signature: []const u8 = "code-signature",
    hover: []const u8 = "code-hover",
    /// The colour picker a swatch opens; its parts are named after it.
    picker: []const u8 = "code-picker",
    /// The button after the path the caret is in, which has another chosen.
    choose: []const u8 = "code-choose",
    /// The find bar; its fields and buttons are named after it.
    find: []const u8 = "code-find",
};

/// How the interface measures the code, for `Document.Metrics`: keep one
/// where it will not move, and point the document at it.
pub const Ruler = struct {
    ui: ?*Ui = null,
    style: ui_lib.TextStyle = .{},

    pub fn measure(self: *const Ruler) Document.Measure {
        return .{ .context = self, .widthFn = widthOf };
    }

    fn widthOf(context: ?*const anyopaque, run: []const u8) f32 {
        const self: *const Ruler = @ptrCast(@alignCast(context.?));
        const ui = self.ui orelse return 0;
        const measurer = ui.measurer orelse return 0;
        return measurer.measure(run, self.style).width;
    }
};

/// One character's width, near enough for the widths of popups and the room
/// left round them.
fn em(ed: *const Document) f32 {
    return @max(1, ed.metrics.measure.width("0"));
}

pub fn gutterWidth(ed: *const Document) f32 {
    var digits: usize = 1;
    var n = ed.buffer.lineCount();
    while (n >= 10) : (n /= 10) digits += 1;
    var widest: [12]u8 = @splat('0');
    return ed.metrics.measure.width(widest[0..@max(digits, 3)]) + 2.5 * em(ed);
}

fn style(v: View, ed: *const Document, color: Color) ui_lib.TextStyle {
    return .{ .color = color, .font_size = ed.metrics.font_size, .wrap = .none, .line_height = @intFromFloat(ed.metrics.line_height), .font = v.font };
}

fn proseStyle(v: View, ed: *const Document, color: Color) ui_lib.TextStyle {
    var s = v.style(ed, color);
    s.font = v.prose_font;
    return s;
}

/// Where the view went, once the frame is laid out: what the next frame
/// scrolls by and the pointer is measured against. `scale` is how many of
/// the interface's pixels a pixel of the code's is.
pub fn measure(v: View, ed: *Document, ui: *Ui, scale: f32) void {
    const box = ui.boxOf(v.ids.code) orelse return;
    ed.view = .{ box.x / scale, box.y / scale, box.width / scale, box.height / scale };
    ed.rows = @max(1, @as(u32, @intFromFloat(@max(0, ed.view[3] / ed.metrics.line_height))));
    ed.gutter = gutterWidth(ed);
}

/// Whether the code has the keyboard: it was pressed, or given it with
/// `focus`, and nothing has taken it since. It takes every key then, Tab
/// too: the interface does not move on from it.
pub fn hasKeys(v: View, ui: *Ui) bool {
    return ui.isFocused(v.ids.code);
}

/// Gives the code the keyboard.
pub fn focus(v: View, ui: *Ui) void {
    ui.setFocus(v.ids.code);
}

/// The code view, and the find bar over it while it is open. `focused` is
/// whether the code has the keyboard, which is when the caret shows: its
/// window's and `hasKeys`.
pub fn draw(v: View, ed: *Document, ui: *Ui, focused: bool) void {
    ed.follow();
    ui.open(.{ .width = .grow, .height = .grow, .direction = .top_to_bottom });
    defer ui.close();
    if (ed.find.open) v.findBar(ed, ui);
    ui.open(.{
        .id = v.ids.code,
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .background_color = v.theme.code,
        .clip = .both,
        .cursor = .ibeam,
        .focus = .{ .keys = .all, .tab_stop = false },
    });
    defer ui.close();
    ed.gutter = gutterWidth(ed);
    // The minimap, when there is one and room for it, and the scrollbar.
    ed.aside = if (v.minimap_texture != null and ed.view[2] >= 3 * minimap_columns) minimap_columns + 12 else 12;
    // Its rows and marks float over it, and fluxion-ui takes the pointer's
    // shape from what it is over, which stops at a float: the view says
    // its own wherever the pointer is on it.
    if (v.under(ui)) ui.setCursor(shapeAt(ed, ui.pointer.position.x));
    var line = ed.top;
    const last = @min(ed.buffer.lineCount(), ed.top + ed.rows + 1);
    while (line < last) : (line += 1) v.row(ed, ui, line);
    v.gutterColumn(ed, ui);
    v.found(ed, ui);
    v.selection(ed, ui);
    v.mistakes(ed, ui);
    if (focused and @mod(ed.now - ed.typed_at, 1.0) < 0.6) v.caret(ed, ui);
    scrollbar(ed, ui);
    v.minimap(ed, ui);
    v.completion(ed, ui);
    v.signature(ed, ui);
    v.hover(ed, ui);
    v.picker(ed, ui);
    v.chooser(ed, ui);
}

/// A button after the path the caret is in, which asks the host to have
/// another chosen.
fn chooser(v: View, ed: *Document, ui: *Ui) void {
    const b = &ed.buffer;
    const at = ed.pathAt(b.cursor) orelse return;
    const line = b.lineOf(at[1]);
    if (!inView(ed, line)) return;
    if (ui.isElementReleased(v.ids.choose)) ed.choosing = at;
    const after = @min(at[1] + 1, b.lineEnd(line));
    ui.open(.{
        .id = v.ids.choose,
        .height = .fixed(ed.metrics.line_height),
        .padding = .xy(4, 0),
        .align_y = .center,
        .corner_radius = .all(3),
        .border = .all(v.theme.border, 1),
        .background_color = if (ui.isPointerOver(v.ids.choose)) v.theme.hover else v.theme.popup,
        .floating = .{ .offset = .{ .x = xOf(ed, after) + 4, .y = yOf(ed, line) }, .z_index = 19 },
    });
    ui.text("...", v.style(ed, v.theme.ink));
    ui.close();
}

// ---------------------------------------------------------------------------
// The minimap

/// How many characters of a line the minimap shows, a pixel each, and how
/// many pixels tall it can be: a line is two while they fit.
pub const minimap_columns = 96;
pub const minimap_most_rows = 4096;

/// The minimap: the code in its colours, a pixel a character and two a
/// line, into `out` as RGBA rows - if the text changed since the host last
/// made it, with its size; null when what the host has is the text's.
pub fn minimapPixels(v: View, ed: *Document, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) std.mem.Allocator.Error!?[2]u32 {
    ed.refresh();
    if (ed.minimap_of == ed.buffer.version and ed.minimap_size[1] > 0) return null;
    const b = &ed.buffer;
    const text = b.text.items;
    const lines = b.lineCount();
    const width: u32 = minimap_columns;
    const height: u32 = @min(lines * 2, minimap_most_rows);
    try out.resize(gpa, @as(usize, width) * height * 4);
    @memset(out.items, 0);
    const tab: u32 = @max(ed.metrics.tab_width, 1);
    var t: usize = 0;
    var line: u32 = 0;
    while (line < lines) : (line += 1) {
        const y: usize = @intCast(@as(u64, line) * height / lines);
        const end = b.lineEnd(line);
        var at = b.lineStart(line);
        var column: u32 = 0;
        while (at < end and column < width) : (at += 1) {
            const c = text[at];
            if (c & 0xC0 == 0x80) continue;
            if (c == '\t') {
                column = (column / tab + 1) * tab;
                continue;
            }
            if (c != ' ') {
                while (t < ed.tokens.len and ed.tokens[t].start + ed.tokens[t].len <= at) t += 1;
                const color = if (t < ed.tokens.len and ed.tokens[t].start <= at) v.theme.style(ed.tokens[t].style) else v.theme.ink;
                const i = (y * width + column) * 4;
                out.items[i..][0..4].* = .{ byte(color.r), byte(color.g), byte(color.b), 200 };
            }
            column += 1;
        }
    }
    ed.minimap_of = b.version;
    ed.minimap_size = .{ width, height };
    return ed.minimap_size;
}

fn byte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// How far down the minimap is scrolled, in its pixels: as far through what
/// does not fit as the view is through the lines.
fn minimapOffset(ed: *const Document) f32 {
    const tall: f32 = @floatFromInt(ed.minimap_size[1]);
    const h = @max(ed.view[3], 1);
    const total = ed.buffer.lineCount();
    if (tall <= h or total <= ed.rows) return 0;
    const progress = @min(1, @as(f32, @floatFromInt(ed.top)) / @as(f32, @floatFromInt(total - ed.rows)));
    return progress * (tall - h);
}

/// The minimap beside the scrollbar, and the lines in view lit on it.
fn minimap(v: View, ed: *Document, ui: *Ui) void {
    const texture = v.minimap_texture orelse return;
    if (ed.aside <= 12 or ed.minimap_size[1] == 0) return;
    const w: f32 = @floatFromInt(ed.minimap_size[0]);
    const tall: f32 = @floatFromInt(ed.minimap_size[1]);
    const shown = @min(tall, @max(ed.view[3], 1));
    const offset = minimapOffset(ed);
    const x = ed.view[2] - ed.aside;
    rect(ui, x, 0, w, @max(ed.view[3], 1), v.theme.code, 7);
    ui.empty(.{
        .width = .fixed(w),
        .height = .fixed(shown),
        .image = .{ .texture = texture, .source = .init(0, offset / tall, 1, shown / tall) },
        .floating = .{ .offset = .{ .x = x, .y = 0 }, .z_index = 7, .clip = true },
    });
    const lines: f32 = @floatFromInt(ed.buffer.lineCount());
    const top: f32 = @floatFromInt(ed.top);
    const rows: f32 = @floatFromInt(ed.rows);
    const color: Color = if (ed.drag == .minimap) .bytes(160, 160, 160, 60) else .bytes(128, 128, 128, 40);
    rect(ui, x, top * tall / lines - offset, w, @max(4, @min(rows, lines) * tall / lines), color, 8);
}

/// The view scrolled to the line at `y` on the minimap, as it was scrolled
/// when it was pressed: that line in the middle.
fn scrollToMinimap(ed: *Document, y: f32) void {
    const tall: f32 = @floatFromInt(@max(ed.minimap_size[1], 1));
    const total = ed.buffer.lineCount();
    const at = std.math.clamp((y + ed.minimap_from) / tall, 0, 1);
    const line: u32 = @intFromFloat(at * @as(f32, @floatFromInt(total)));
    ed.top = @min(line -| ed.rows / 2, total -| ed.rows);
}

/// Where the swatch of the colour from `start` is on the view, from its
/// top left: x, y, and its side.
fn swatchBox(ed: *const Document, start: u32) [3]f32 {
    const line = ed.buffer.lineOf(start);
    return .{ xOf(ed, start) - ed.swatchWidth(), yOf(ed, line), ed.swatchWidth() };
}

/// The colour picker a swatch opened, under the swatch, with a button for
/// each way the language writes a colour.
fn picker(v: View, ed: *Document, ui: *Ui) void {
    const p = if (ed.picking) |*p| p else return;
    const at = ed.colorAt(p.start) orelse return;
    const line = ed.buffer.lineOf(p.start);
    if (!inView(ed, line)) return;
    const box = swatchBox(ed, p.start);
    ui.open(.{
        .id = v.ids.picker,
        .direction = .top_to_bottom,
        .padding = .all(8),
        .gap = 8,
        .background_color = v.theme.popup,
        .border = .all(v.theme.border, 1),
        .corner_radius = .all(4),
        .capture = true,
        .floating = .{ .offset = .{ .x = @max(0, box[0]), .y = box[1] + ed.metrics.line_height + 2 }, .z_index = 24 },
    });
    defer ui.close();
    const look: ui_lib.ColorPicker.Style = .{
        .text = v.theme.ink,
        .dim = v.theme.dim,
        .field = v.theme.code,
        .border = v.theme.border,
        .accent = v.theme.accent,
    };
    if (ui_lib.ColorPicker.picker(ui, &p.state, .{ .id = v.ids.picker, .size = 160, .style = look })) {
        _ = ed.setColor(p.start, p.state.color(), null) catch {};
    }
    // The ways to write it: the one it is in lit.
    ui.open(.{ .direction = .left_to_right, .gap = 4 });
    defer ui.close();
    for (ed.language.colors, 0..) |form, i| {
        var name: [96]u8 = undefined;
        const id = std.fmt.bufPrint(&name, "{s}-form-{d}", .{ v.ids.picker, i }) catch v.ids.picker;
        var scratch: [128]u8 = undefined;
        const can = colors.write(&scratch, form, p.state.color(), "") != null;
        if (can and ui.isElementReleased(id)) _ = ed.setColor(p.start, p.state.color(), @intCast(i)) catch {};
        var label_buffer: [48]u8 = undefined;
        const lit = at.form == i;
        ui.open(.{
            .id = id,
            .padding = .xy(6, 2),
            .corner_radius = .all(3),
            .border = .all(v.theme.border, 1),
            .background_color = if (lit) v.theme.popup_selected else if (can and ui.isPointerOver(id)) v.theme.hover else .transparent,
        });
        ui.text(form.label(&label_buffer), v.style(ed, if (can) v.theme.ink else v.theme.faint));
        ui.close();
    }
}

fn row(v: View, ed: *Document, ui: *Ui, line: u32) void {
    const m = ed.metrics;
    const b = &ed.buffer;
    if (line == b.lineOf(b.cursor) and b.selection() == null) {
        rect(ui, 0, yOf(ed, line), @max(ed.view[2], 1), m.line_height, v.theme.current_line, 0);
    }

    // Tokens in their colours, what is between them plain.
    ui.open(.{
        .height = .fixed(m.line_height),
        .direction = .left_to_right,
        .floating = .{ .offset = .{ .x = ed.gutter - ed.left, .y = yOf(ed, line) }, .z_index = 1, .clip = true },
    });
    defer ui.close();
    const start = b.lineStart(line);
    const end = b.lineEnd(line);
    var at = start;
    var t = ed.firstToken(start);
    var c = ed.firstColor(start);
    while (at < end) {
        var until = end;
        var color = v.theme.ink;
        if (t < ed.tokens.len) {
            const token = ed.tokens[t];
            if (token.start <= at) {
                until = @min(end, token.start + token.len);
                color = v.theme.style(token.style);
            } else until = @min(end, token.start);
        }
        // A colour's swatch before it, taking room in the line.
        while (c < ed.colors.len and ed.colors[c].start <= at) : (c += 1) {
            if (ed.colors[c].start == at) v.swatch(ed, ui, ed.colors[c].color);
        }
        if (c < ed.colors.len and ed.colors[c].start < until) until = ed.colors[c].start;
        if (until > at) v.textRun(ed, ui, start, at, until, color);
        at = @max(until, at + 1);
        while (t < ed.tokens.len and ed.tokens[t].start + ed.tokens[t].len <= at) t += 1;
    }
}

/// The square of a colour in front of it, over grey so its alpha shows.
fn swatch(v: View, ed: *const Document, ui: *Ui, c: Color) void {
    const w = ed.swatchWidth();
    const side = @round(ed.metrics.line_height * 0.6);
    ui.open(.{ .width = .fixed(w), .height = .fixed(ed.metrics.line_height), .align_x = .center, .align_y = .center });
    ui.open(.{ .width = .fixed(side), .height = .fixed(side), .padding = .all(1), .background_color = .hex(0x808080), .border = .all(v.theme.border, 1) });
    ui.empty(.{ .width = .grow, .height = .grow, .background_color = c });
    ui.close();
    ui.close();
}

/// `text[from..until]` of the line starting at `line_start`, in `color`: a
/// tab in it is room to the next stop.
fn textRun(v: View, ed: *Document, ui: *Ui, line_start: u32, from: u32, until: u32, color: Color) void {
    const text = ed.buffer.text.items;
    var at = from;
    while (at < until) {
        const tab = std.mem.indexOfScalarPos(u8, text[0..until], at, '\t') orelse until;
        if (tab > at) ui.text(text[at..tab], v.style(ed, color));
        if (tab == until) break;
        const before = ed.widthOf(text[line_start..tab]);
        const after = ed.widthOf(text[line_start .. tab + 1]);
        ui.empty(.{ .width = .fixed(@max(after - before, 1)), .height = .fixed(ed.metrics.line_height) });
        at = @intCast(tab + 1);
    }
}

/// The line numbers, red or yellow where something on the line is wrong.
fn gutterColumn(v: View, ed: *Document, ui: *Ui) void {
    const b = &ed.buffer;
    rect(ui, 0, 0, ed.gutter, @max(ed.view[3], 1), v.theme.gutter, 4);
    const current = b.lineOf(b.cursor);
    var line = ed.top;
    const last = @min(b.lineCount(), ed.top + ed.rows + 1);
    while (line < last) : (line += 1) {
        var color = if (line == current) v.theme.line_number_current else v.theme.line_number;
        for (ed.problems) |p| if (p.line == line) {
            color = if (p.severity == .@"error") v.theme.error_ink else v.theme.warning_ink;
            if (p.severity == .@"error") break;
        };
        var digits: [12]u8 = undefined;
        ui.open(.{
            .width = .fixed(ed.gutter - 1.5 * em(ed)),
            .height = .fixed(ed.metrics.line_height),
            .align_x = .right,
            .floating = .{ .offset = .{ .x = 0, .y = yOf(ed, line) }, .z_index = 5, .clip = true },
        });
        ui.text(std.fmt.bufPrint(&digits, "{d}", .{line + 1}) catch "?", v.style(ed, color));
        ui.close();
    }
}

/// A rectangle over the view, at a place in it.
fn rect(ui: *Ui, x: f32, y: f32, w: f32, h: f32, color: Color, z: i16) void {
    ui.empty(.{
        .width = .fixed(@max(w, 1)),
        .height = .fixed(h),
        .background_color = color,
        .floating = .{ .offset = .{ .x = x, .y = y }, .z_index = z, .clip = true },
    });
}

/// Where an offset of the text is in the view, sideways.
fn xOf(ed: *const Document, offset: u32) f32 {
    return ed.gutter + ed.xOf(offset) - ed.left;
}

fn yOf(ed: *const Document, line: u32) f32 {
    return (@as(f32, @floatFromInt(line)) - @as(f32, @floatFromInt(ed.top))) * ed.metrics.line_height;
}

fn inView(ed: *const Document, line: u32) bool {
    return line >= ed.top and line <= ed.top + ed.rows;
}

fn selection(v: View, ed: *Document, ui: *Ui) void {
    const b = &ed.buffer;
    const s = b.selection() orelse return;
    const first = b.lineOf(s[0]);
    const last = b.lineOf(s[1]);
    var line = @max(first, ed.top);
    while (line <= @min(last, ed.top + ed.rows)) : (line += 1) {
        const from = if (line == first) s[0] else b.lineStart(line);
        const to = if (line == last) s[1] else b.lineEnd(line);
        if (to < from) continue;
        // A selected line break shows as a sliver past the line's end.
        const tail: f32 = if (line == last) 0 else em(ed) / 2;
        const x = @max(ed.gutter, xOf(ed, from));
        rect(ui, x, yOf(ed, line), xOf(ed, to) + tail - x, ed.metrics.line_height, v.theme.selection, 2);
    }
}

/// Behind every place in view that the find bar's words are.
fn found(v: View, ed: *Document, ui: *Ui) void {
    const query = ed.find.query.items;
    if (!ed.find.open or ed.find.mode == .line or query.len == 0) return;
    const b = &ed.buffer;
    const text = b.text.items;
    var line = ed.top;
    const last = @min(b.lineCount(), ed.top + ed.rows + 1);
    while (line < last) : (line += 1) {
        var at = b.lineStart(line);
        const end = b.lineEnd(line);
        while (at + query.len <= end) {
            if (search.isAt(text, query, at, ed.find.options)) {
                const to: u32 = @intCast(at + query.len);
                const x = @max(ed.gutter, xOf(ed, at));
                rect(ui, x, yOf(ed, line), xOf(ed, to) - x, ed.metrics.line_height, v.theme.match, 1);
                at = to;
            } else at += 1;
        }
    }
}

fn mistakes(v: View, ed: *Document, ui: *Ui) void {
    const b = &ed.buffer;
    for (ed.problems) |p| {
        if (!inView(ed, p.line)) continue;
        const end = if (b.lineOf(p.end) == p.line) p.end else b.lineEnd(p.line);
        const x = @max(ed.gutter, xOf(ed, p.start));
        const width = @max(em(ed) / 2, xOf(ed, end) - x);
        const color = if (p.severity == .@"error") v.theme.error_ink else v.theme.warning_ink;
        rect(ui, x, yOf(ed, p.line) + ed.metrics.line_height - 2, width, 2, color, 3);
    }
}

fn caret(v: View, ed: *Document, ui: *Ui) void {
    const b = &ed.buffer;
    const line = b.lineOf(b.cursor);
    if (!inView(ed, line)) return;
    const x = xOf(ed, b.cursor);
    if (x < ed.gutter) return;
    rect(ui, x - 1, yOf(ed, line), 2, ed.metrics.line_height, v.theme.caret, 6);
}

fn scrollbar(ed: *Document, ui: *Ui) void {
    const total = ed.buffer.lineCount();
    if (total <= ed.rows) return;
    const h = ed.view[3];
    const thumb = @max(24, h * @as(f32, @floatFromInt(ed.rows)) / @as(f32, @floatFromInt(total)));
    const progress = @as(f32, @floatFromInt(ed.top)) / @as(f32, @floatFromInt(total - ed.rows));
    const color: Color = if (ed.drag == .scrollbar) .bytes(160, 160, 160, 160) else .bytes(128, 128, 128, 90);
    rect(ui, ed.view[2] - 10, @min(1, progress) * (h - thumb), 7, thumb, color, 7);
}

fn completion(v: View, ed: *Document, ui: *Ui) void {
    const c = &ed.completion;
    if (!c.open or c.shown.items.len == 0) return;
    const m = ed.metrics;
    var widest: usize = 12;
    for (c.shown.items) |i| widest = @max(widest, c.items[i].label.len);
    const width = std.math.clamp(@as(f32, @floatFromInt(widest + 28)) * em(ed), 280, 620);
    // Under the word being completed.
    const x = @max(ed.gutter, xOf(ed, c.start));
    const y = yOf(ed, ed.buffer.lineOf(ed.buffer.cursor)) + m.line_height + 2;
    ui.open(.{
        .id = v.ids.completion,
        .width = .fixed(width),
        .direction = .top_to_bottom,
        .padding = .all(3),
        .background_color = v.theme.popup,
        .border = .all(v.theme.border, 1),
        .corner_radius = .all(4),
        .capture = true,
        .preserve_focus = true,
        .floating = .{ .offset = .{ .x = x - 2 * em(ed), .y = y }, .z_index = 20 },
    });
    const last = @min(c.shown.items.len, c.first + Document.visible_items);
    var clicked: ?usize = null;
    for (c.shown.items[c.first..last], c.first..) |index, i| {
        const item = c.items[index];
        var name: [96]u8 = undefined;
        const row_id = std.fmt.bufPrint(&name, "{s}-{d}", .{ v.ids.completion, i }) catch v.ids.completion;
        if (ui.isElementReleased(row_id)) clicked = i;
        ui.open(.{
            .id = row_id,
            .width = .grow,
            .height = .fixed(m.line_height + 4),
            .direction = .left_to_right,
            .align_y = .center,
            .padding = .xy(6, 0),
            .gap = @intFromFloat(em(ed)),
            .corner_radius = .all(3),
            .background_color = if (i == c.selected) v.theme.popup_selected else if (ui.isPointerOver(row_id)) v.theme.hover else .transparent,
        });
        if (item.swatch) |rgba| {
            const side = @round(m.line_height * 0.6);
            ui.empty(.{ .width = .fixed(side), .height = .fixed(side), .background_color = .rgba(rgba[0], rgba[1], rgba[2], rgba[3]), .border = .all(v.theme.border, 1) });
        } else {
            const letter, const color = v.theme.kind(item.kind);
            ui.text(letter, v.style(ed, color));
        }
        ui.text(item.label, v.style(ed, v.theme.ink));
        ui.open(.{ .width = .grow, .height = .fixed(m.line_height), .clip = .x, .padding = .trbl(0, 0, 0, @intFromFloat(em(ed))) });
        if (item.detail.len > 0 and item.detail[0] != ' ') ui.text(item.detail, v.style(ed, v.theme.dim));
        ui.close();
        ui.close();
    }
    if (c.shown.items.len > Document.visible_items) {
        var count: [32]u8 = undefined;
        ui.open(.{ .width = .grow, .padding = .xy(6, 2), .align_x = .right });
        ui.text(std.fmt.bufPrint(&count, "{d} of {d}", .{ c.selected + 1, c.shown.items.len }) catch "", v.style(ed, v.theme.faint));
        ui.close();
    }
    ui.close();

    // What the chosen one is, beside the list.
    if (ed.selectedItem()) |item| if (item.doc != null or item.detail.len > 40) {
        ui.open(.{
            .id = v.ids.completion_doc,
            .width = .fixed(46 * em(ed)),
            .direction = .top_to_bottom,
            .gap = 6,
            .padding = .all(8),
            .background_color = v.theme.tooltip,
            .border = .all(v.theme.border, 1),
            .corner_radius = .all(4),
            .floating = .{ .attach = .id, .to = v.ids.completion, .anchor = .after, .offset = .{ .x = 4, .y = 0 }, .z_index = 21 },
        });
        wrapped(ui, item.detail, v.style(ed, v.theme.ink));
        if (item.doc) |doc| wrapped(ui, doc, v.proseStyle(ed, v.theme.dim));
        ui.close();
    };
    if (clicked) |i| {
        ed.completion.selected = i;
        ed.accept(i) catch {};
    }
}

/// Prose, broken into lines to fit its box.
fn wrapped(ui: *Ui, text: []const u8, text_style: ui_lib.TextStyle) void {
    var s = text_style;
    s.wrap = .words;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len == 0) continue;
        ui.open(.{ .width = .grow });
        ui.text(trimmed, s);
        ui.close();
    }
}

fn signature(v: View, ed: *Document, ui: *Ui) void {
    const sig = ed.signature orelse return;
    if (ed.completion.open) return;
    const m = ed.metrics;
    const b = &ed.buffer;
    const line = b.lineOf(b.cursor);
    if (!inView(ed, line)) return;
    // Above the line, its bottom edge on the line's top; under it when the
    // line is the first in view.
    const above = line > ed.top + 2;
    const y = if (above) yOf(ed, line) - 3 else yOf(ed, line) + m.line_height + 2;
    ui.open(.{
        .id = v.ids.signature,
        .direction = .top_to_bottom,
        .padding = .xy(8, 4),
        .gap = 4,
        .background_color = v.theme.tooltip,
        .border = .all(v.theme.border, 1),
        .corner_radius = .all(4),
        .floating = .{
            .offset = .{ .x = @max(ed.gutter, xOf(ed, b.cursor) - 4 * em(ed)), .y = y },
            .anchor = .{ .element_y = if (above) .bottom else .top },
            .z_index = 22,
        },
        // Something to read, not to press: the text under it answers.
        .passthrough = true,
    });
    defer ui.close();
    ui.open(.{ .direction = .left_to_right });
    const active: ?[2]u32 = if (sig.active < sig.params.len) sig.params[sig.active] else null;
    const label = sig.label;
    if (active) |p| {
        ui.text(label[0..p[0]], v.style(ed, v.theme.ink));
        ui.text(label[p[0]..p[1]], v.style(ed, v.theme.accent));
        ui.text(label[p[1]..], v.style(ed, v.theme.ink));
    } else ui.text(label, v.style(ed, v.theme.ink));
    ui.close();
    if (sig.doc) |doc| {
        ui.open(.{ .width = .fixed(60 * em(ed)) });
        wrapped(ui, doc, v.proseStyle(ed, v.theme.dim));
        ui.close();
    }
}

fn hover(v: View, ed: *Document, ui: *Ui) void {
    const h = ed.hover.shown orelse return;
    if (ed.completion.open) return;
    const b = &ed.buffer;
    const line = b.lineOf(@min(h.start, b.len()));
    if (!inView(ed, line)) return;
    ui.open(.{
        .id = v.ids.hover,
        .direction = .top_to_bottom,
        .padding = .all(8),
        .gap = 6,
        .background_color = v.theme.tooltip,
        .border = .all(v.theme.border, 1),
        .corner_radius = .all(4),
        .floating = .{ .offset = .{ .x = @max(ed.gutter, xOf(ed, @min(h.start, b.len()))), .y = yOf(ed, line) + ed.metrics.line_height + 2 }, .z_index = 23 },
        // Something to read, not to press: the text under it answers.
        .passthrough = true,
    });
    defer ui.close();
    var lines = std.mem.splitScalar(u8, h.code, '\n');
    while (lines.next()) |code| {
        ui.open(.{ .direction = .left_to_right });
        ui.text(code, v.style(ed, v.theme.style(.function)));
        ui.close();
    }
    if (h.doc) |doc| {
        ui.open(.{ .width = .fixed(60 * em(ed)), .direction = .top_to_bottom, .gap = 2 });
        wrapped(ui, doc, v.proseStyle(ed, v.theme.ink));
        ui.close();
    }
}

// ---------------------------------------------------------------------------
// The find bar

/// A name of the find bar's, made from its own: `code-find-next`.
fn part(v: View, buffer: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}-{s}", .{ v.ids.find, name }) catch v.ids.find;
}

/// The find bar: the words to find, what they become, or the line to go to,
/// with its buttons. Its fields have the keyboard while they are typed in.
fn findBar(v: View, ed: *Document, ui: *Ui) void {
    var names: [4][64]u8 = undefined;
    const query_id = v.part(&names[0], "query");
    const replacement_id = v.part(&names[1], "replacement");
    const line_id = v.part(&names[2], "line");

    const f = &ed.find;
    // The keyboard and what the query holds go into the field once it is
    // there: it is not, the frame the bar opens.
    if (f.focus) switch (f.mode) {
        .line => if (ui.textValueOf(line_id) != null) {
            f.focus = false;
            ui.setTextValue(line_id, "");
            ui.setFocus(line_id);
        },
        .find, .replace => if (ui.textValueOf(query_id) != null) {
            f.focus = false;
            ui.setTextValue(query_id, f.query.items);
            if (ui.textValueOf(replacement_id) != null) ui.setTextValue(replacement_id, f.replacement.items);
            ui.setFocus(query_id);
        },
    };

    ui.open(.{ .id = v.ids.find, .width = .grow, .direction = .top_to_bottom, .padding = .xy(8, 5), .gap = 4, .background_color = v.theme.bar });
    defer ui.close();
    switch (f.mode) {
        .line => {
            ui.open(.{ .width = .grow, .direction = .left_to_right, .gap = 6, .align_y = .center });
            ui.text("Go to line", v.proseStyle(ed, v.theme.dim));
            v.field(ed, ui, line_id, "", .fixed(10 * em(ed)));
            var count: [32]u8 = undefined;
            ui.text(std.fmt.bufPrint(&count, "of {d}", .{ed.buffer.lineCount()}) catch "", v.proseStyle(ed, v.theme.faint));
            ui.empty(.{ .width = .grow });
            if (v.button(ed, ui, v.part(&names[3], "close"), "\u{00D7}", false)) ed.closeFind();
            ui.close();
            if (ui.textSubmitted(line_id)) {
                const typed = std.mem.trim(u8, ui.textValueOf(line_id) orelse "", " ");
                if (std.fmt.parseInt(u32, typed, 10)) |number| ed.goToLine(number) else |_| {}
            }
        },
        .find, .replace => {
            ui.open(.{ .width = .grow, .direction = .left_to_right, .gap = 6, .align_y = .center });
            v.field(ed, ui, query_id, "Find", .grow);
            var count: [32]u8 = undefined;
            const n = ed.matches();
            const said = if (f.query.items.len == 0) "" else if (n == 0) "none" else std.fmt.bufPrint(&count, "{d} found", .{n}) catch "";
            ui.text(said, v.proseStyle(ed, if (n == 0) v.theme.warning_ink else v.theme.dim));
            if (v.button(ed, ui, v.part(&names[3], "previous"), "\u{2191}", false)) _ = ed.findNext(false);
            if (v.button(ed, ui, v.part(&names[3], "next"), "\u{2193}", false)) _ = ed.findNext(true);
            if (v.button(ed, ui, v.part(&names[3], "case"), "Aa", f.options.match_case)) f.options.match_case = !f.options.match_case;
            if (v.button(ed, ui, v.part(&names[3], "word"), "W", f.options.whole_word)) f.options.whole_word = !f.options.whole_word;
            if (v.button(ed, ui, v.part(&names[3], "close"), "\u{00D7}", false)) ed.closeFind();
            ui.close();
            if (f.mode == .replace) {
                ui.open(.{ .width = .grow, .direction = .left_to_right, .gap = 6, .align_y = .center });
                v.field(ed, ui, replacement_id, "Replace with", .grow);
                if (v.button(ed, ui, v.part(&names[3], "replace"), "Replace", false)) ed.replaceOne() catch {};
                if (v.button(ed, ui, v.part(&names[3], "all"), "All", false)) _ = ed.replaceAll() catch 0;
                ui.close();
            }
            if (ui.textChanged(query_id)) ed.setQuery(ui.textValueOf(query_id) orelse "") catch {};
            if (ui.textSubmitted(query_id)) {
                _ = ed.findNext(true);
                ui.setFocus(query_id);
            }
            if (ui.textChanged(replacement_id)) ed.setReplacement(ui.textValueOf(replacement_id) orelse "") catch {};
            if (ui.textSubmitted(replacement_id)) {
                ed.replaceOne() catch {};
                ui.setFocus(replacement_id);
            }
        },
    }
}

fn field(v: View, ed: *const Document, ui: *Ui, id: []const u8, placeholder: []const u8, width: ui_lib.Sizing) void {
    ui.textInput(.{
        .id = id,
        .width = width,
        .height = .fixed(ed.metrics.line_height + 6),
        .padding = .xy(6, 3),
        .background_color = v.theme.field,
        .border = .all(if (ui.isFocused(id)) v.theme.accent else v.theme.border, 1),
        .corner_radius = .all(3),
    }, .{
        .placeholder = placeholder,
        .font_size = ed.metrics.font_size,
        .text_color = v.theme.ink,
        .placeholder_color = v.theme.faint,
        .cursor_color = v.theme.caret,
        .selection_color = v.theme.selection,
    });
}

/// A small button of the bar, lit while `on`. Whether it was pressed.
fn button(v: View, ed: *const Document, ui: *Ui, id: []const u8, label: []const u8, on: bool) bool {
    const pressed = ui.isElementReleased(id);
    ui.open(.{
        .id = id,
        .height = .fixed(ed.metrics.line_height + 6),
        .padding = .xy(8, 0),
        .align_y = .center,
        .corner_radius = .all(3),
        .preserve_focus = true,
        .background_color = if (on) v.theme.popup_selected else if (ui.isPointerOver(id)) v.theme.hover else v.theme.popup,
        .border = .all(if (on) v.theme.accent else v.theme.border, 1),
    });
    ui.text(label, v.proseStyle(ed, v.theme.ink));
    ui.close();
    return pressed;
}

// ---------------------------------------------------------------------------
// The mouse

/// Whether the pointer is on the view - its text, the rows and the marks
/// laid over it, a tooltip - and not on the list of completions or on
/// anything else laid over it: where a press takes the keyboard and the
/// wheel scrolls the text. The rows float over the view, so fluxion-ui's
/// `isPointerOver` stops at them; `isPointerWithin` sees past.
pub fn under(v: View, ui: *Ui) bool {
    return ui.isPointerWithin(v.ids.code) and !v.overList(ui);
}

/// The colour whose swatch is at (`x`, `y`) of the view, by where it starts.
fn swatchUnder(ed: *const Document, x: f32, y: f32) ?u32 {
    const row_at: i64 = @intFromFloat(@floor(y / ed.metrics.line_height));
    if (row_at < 0) return null;
    const line = ed.top + @as(u32, @intCast(row_at));
    if (line >= ed.buffer.lineCount()) return null;
    const start = ed.buffer.lineStart(line);
    var i = ed.firstColor(start);
    while (i < ed.colors.len and ed.colors[i].start <= ed.buffer.lineEnd(line)) : (i += 1) {
        const box = swatchBox(ed, ed.colors[i].start);
        if (x >= box[0] and x < box[0] + box[2]) return ed.colors[i].start;
    }
    return null;
}

/// The pointer's shape at `x` on the view: an arrow on the line numbers and
/// the scrollbar, the text's caret on the text.
fn shapeAt(ed: *const Document, x: f32) ui_lib.CursorShape {
    const x0, _, const w, _ = ed.view;
    if (x < x0 + ed.gutter or x >= x0 + w - @max(12, ed.aside)) return .arrow;
    return .ibeam;
}

/// Whether the pointer is on the list of completions or the doc beside it,
/// which answer it themselves.
fn overList(v: View, ui: *Ui) bool {
    return ui.isPointerWithin(v.ids.completion) or ui.isPointerWithin(v.ids.completion_doc) or ui.isPointerWithin(v.ids.picker) or ui.isPointerWithin(v.ids.choose);
}

pub const Pointer = struct {
    x: f32,
    y: f32,
    down: bool,
    pressed: bool,
    mods: Document.Mods,
};

/// What the mouse did to the text, from where everything was last frame:
/// a click puts the caret, a drag selects, a second click takes the word
/// and a third the line; ctrl and a click goes to the declaration; and
/// resting on a name shows what it is.
pub fn pointer(v: View, ed: *Document, ui: *Ui, p: Pointer) void {
    const x0, const y0, const w, const h = ed.view;
    const gutter = ed.gutter;
    const inside = p.x >= x0 and p.x < x0 + w and p.y >= y0 and p.y < y0 + h and !v.overList(ui);
    if (!p.down) ed.drag = .none;
    switch (ed.drag) {
        .text => {
            ed.buffer.moveTo(ed.offsetAt(x0, y0, gutter, p.x, p.y), true);
            ed.reveal = true;
            return;
        },
        .scrollbar => {
            const total = ed.buffer.lineCount();
            const fraction = std.math.clamp((p.y - y0) / @max(1, h), 0, 1);
            ed.top = @min(@as(u32, @intFromFloat(fraction * @as(f32, @floatFromInt(total)))), total -| ed.rows);
            return;
        },
        .minimap => return scrollToMinimap(ed, p.y - y0),
        .none => {},
    }
    if (!inside) {
        ed.rest(null);
        return;
    }
    if (p.pressed) {
        v.focus(ui);
        // A colour's swatch opens its picker, and leaves the caret.
        if (swatchUnder(ed, p.x - x0, p.y - y0)) |start| {
            ed.pickColor(start);
            return;
        }
        ed.closePopups();
        if (p.x >= x0 + w - 12 and ed.buffer.lineCount() > ed.rows) {
            ed.drag = .scrollbar;
            return;
        }
        if (ed.aside > 12 and p.x >= x0 + w - ed.aside) {
            ed.drag = .minimap;
            ed.minimap_from = minimapOffset(ed);
            return scrollToMinimap(ed, p.y - y0);
        }
        const at = ed.offsetAt(x0, y0, gutter, p.x, p.y);
        if (p.mods.ctrl) return ed.goToDefinition(at);
        ed.clicks = if (ed.now - ed.last_click < 0.4 and at == ed.click_offset) ed.clicks % 3 + 1 else 1;
        ed.last_click = ed.now;
        ed.click_offset = at;
        switch (ed.clicks) {
            1 => {
                ed.buffer.moveTo(at, p.mods.shift);
                ed.drag = .text;
            },
            2 => ed.buffer.selectWordAt(at),
            else => {
                const line = ed.buffer.lineOf(at);
                ed.buffer.moveTo(ed.buffer.lineStart(line), false);
                ed.buffer.moveTo(@min(ed.buffer.len(), ed.buffer.lineEnd(line) + 1), true);
            },
        }
        ed.typed_at = ed.now;
        return;
    }
    if (p.x < x0 + gutter) return ed.rest(null);
    ed.rest(ed.offsetAt(x0, y0, gutter, p.x, p.y));
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const languages = @import("languages.zig");

/// A frame of a view over `ed`, measured the way fluxion-ui's test measurer
/// measures: half the font size a character.
fn frame(view: View, ed: *Document, ui: *Ui, ruler: *Ruler) ![]const ui_lib.RenderCommand {
    ruler.* = .{ .ui = ui, .style = .{ .font_size = ed.metrics.font_size } };
    ed.metrics.measure = ruler.measure();
    ui.begin(.init(800, 600));
    ui.open(.{ .width = .grow, .height = .grow });
    view.draw(ed, ui, true);
    ui.close();
    const drawn = try ui.end();
    view.measure(ed, ui, 1);
    return drawn;
}

/// The text run drawn on the row of `line`, from where the code starts.
fn runOn(drawn: []const ui_lib.RenderCommand, ed: *const Document, line: u32, text: []const u8) ?ui_lib.RenderCommand {
    for (drawn) |c| {
        if (c.config != .text) continue;
        if (c.bounding_box.y != @as(f32, @floatFromInt(line)) * ed.metrics.line_height) continue;
        if (c.bounding_box.x < gutterWidth(ed)) continue;
        if (std.mem.eql(u8, c.config.text.text, text)) return c;
    }
    return null;
}

test "a line's indentation is drawn as part of its text, and the caret where the text says" {
    const gpa = testing.allocator;
    var ed: Document = try .init(gpa, "t.json", "{\n    \"a\": {\n        \"b\": 1\n    }\n}\n", languages.json, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    const view: View = .{ .ids = .{ .code = "script-code" } };
    ed.buffer.moveTo(@intCast(std.mem.indexOf(u8, ed.buffer.text.items, "\"b\"").?), false);
    const drawn = try frame(view, &ed, &ui, &ruler);

    // The fourth line, "    }", has no token in it: one run, spaces and all.
    const gutter = gutterWidth(&ed);
    const found_run = runOn(drawn, &ed, 3, "    }") orelse return error.TestExpectedEqual;
    try testing.expectEqual(gutter, found_run.bounding_box.x);
    // A key in the key's colour.
    const key = runOn(drawn, &ed, 1, "\"a\"") orelse return error.TestExpectedEqual;
    try testing.expectEqual(Theme.dark.style(.key), key.config.text.color);

    // The caret before `"b"`, eight characters of eight pixels in, on the
    // third line; and the view found by the name it was given.
    try testing.expectEqual(gutter + 8 * 8, xOf(&ed, ed.buffer.cursor));
    try testing.expectEqual(@as(f32, 800), ed.view[2]);
}

test "a press gives the code the keyboard, every key of it: Tab does not move the focus on" {
    const gpa = testing.allocator;
    var ed: Document = try .init(gpa, "t.txt", "hello\n", languages.plain, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    const view: View = .{};
    _ = try frame(view, &ed, &ui, &ruler);
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expect(!view.hasKeys(&ui));
    const x = gutterWidth(&ed) + 8;
    ui.setPointer(x, 8, true);
    view.pointer(&ed, &ui, .{ .x = x, .y = 8, .down = true, .pressed = true, .mods = .{} });
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expect(view.hasKeys(&ui));
    try testing.expect(ui.wantsKeyboard());
    try testing.expect(!ui.navigate(.next));
    try testing.expect(view.hasKeys(&ui));
}

test "a tab is drawn as room to the next stop" {
    const gpa = testing.allocator;
    var ed: Document = try .init(gpa, "t.txt", "a\tb\n", languages.plain, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    const drawn = try frame(.{}, &ed, &ui, &ruler);
    // A character is eight pixels, a stop four of them: `b` is at 32.
    const b = runOn(drawn, &ed, 0, "b") orelse return error.TestExpectedEqual;
    try testing.expectEqual(gutterWidth(&ed) + 32, b.bounding_box.x);
    try testing.expect(runOn(drawn, &ed, 0, "a") != null);
}

test "code is drawn in the code's font, and a doc in the prose font" {
    const gpa = testing.allocator;
    var ed: Document = try .init(gpa, "t.txt", "fn f() {}\n", languages.plain, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    ed.hover.shown = .{ .start = 3, .end = 4, .code = "fn f()", .doc = "Does nothing." };
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    const view: View = .{ .font = 3, .prose_font = 1 };
    const drawn = try frame(view, &ed, &ui, &ruler);

    var code_runs: usize = 0;
    var docs: usize = 0;
    for (drawn) |c| if (c.config == .text) {
        const t = c.config.text;
        if (std.mem.eql(u8, t.text, "Does nothing.")) {
            try testing.expectEqual(@as(u16, 1), t.font);
            docs += 1;
        } else {
            // The row's runs, the line number, and the hover's declaration.
            try testing.expectEqual(@as(u16, 3), t.font);
            code_runs += 1;
        }
    };
    try testing.expectEqual(@as(usize, 1), docs);
    try testing.expect(code_runs >= 3);
}

test "the view is under the pointer on its words and on its tooltip, and a press goes through the tooltip to the text" {
    const gpa = testing.allocator;
    var ed: Document = try .init(gpa, "t.txt", "fn f() {}\nthe second line of it\nand a third\n", languages.plain, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    const view: View = .{};
    _ = try frame(view, &ed, &ui, &ruler);

    // On a word of the first line: the row floats over the view, so the
    // view is not what the pointer is over, and it is under the pointer.
    const x = ed.gutter + 8 * 4;
    ui.setPointer(x, 8, false);
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expect(!ui.isPointerOver(view.ids.code));
    try testing.expect(view.under(&ui));
    // And the pointer is the text's caret there, on the line the caret is
    // on - lit across - as on any other; an arrow on the line numbers.
    try testing.expectEqual(ui_lib.CursorShape.ibeam, ui.cursor());
    ui.setPointer(2, 8, false);
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expectEqual(ui_lib.CursorShape.arrow, ui.cursor());

    // A tooltip under the first line, over the second: the view is under
    // the pointer there too, and a press goes to the text beneath it.
    ed.hover.shown = .{ .start = 3, .end = 4, .code = "fn f()", .doc = null };
    _ = try frame(view, &ed, &ui, &ruler);
    const tip = ui.boxOf(view.ids.hover) orelse return error.TestExpectedEqual;
    const at: [2]f32 = .{ tip.x + tip.width / 2, tip.y + tip.height / 2 };
    ui.setPointer(at[0], at[1], true);
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expect(view.under(&ui));
    view.pointer(&ed, &ui, .{ .x = at[0], .y = at[1], .down = true, .pressed = true, .mods = .{} });
    try testing.expect(ed.hover.shown == null);
    try testing.expect(ed.buffer.lineOf(ed.buffer.cursor) >= 1);
}

test "the find bar goes over the code, and the places it finds are lit" {
    const gpa = testing.allocator;
    var ed: Document = try .init(gpa, "t.txt", "rock and rock\nno\n", languages.plain, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    const view: View = .{};
    ed.openFind(.find);
    try ed.setQuery("rock");
    _ = try frame(view, &ed, &ui, &ruler);
    _ = try frame(view, &ed, &ui, &ruler);
    const drawn = try frame(view, &ed, &ui, &ruler);

    // The bar is above: the code starts under it, and its field has the
    // keyboard and the words.
    const bar = ui.boxOf(view.ids.find) orelse return error.TestExpectedEqual;
    try testing.expect(ed.view[1] >= bar.y + bar.height);
    try testing.expect(ui.isFocused("code-find-query"));
    try testing.expectEqualStrings("rock", ui.textValueOf("code-find-query").?);
    var lit: usize = 0;
    for (drawn) |c| if (c.config == .rectangle and std.meta.eql(c.config.rectangle.color, Theme.dark.match)) {
        lit += 1;
    };
    try testing.expectEqual(@as(usize, 2), lit);
}

test "a colour's swatch is before it, a press on it opens the picker, and the picker's buttons write it in another form" {
    const gpa = testing.allocator;
    const forms = [_]colors.Form{
        .{ .channels = .{ .call = "color" } },
        .{ .hex = .{ .call = "color" } },
    };
    var lang = languages.plain;
    lang.colors = &forms;
    var ed: Document = try .init(gpa, "t.txt", "tint = color(1, 0, 0)\n", lang, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    const view: View = .{};
    _ = try frame(view, &ed, &ui, &ruler);
    const drawn = try frame(view, &ed, &ui, &ruler);

    // The colour's text after its swatch.
    const run = runOn(drawn, &ed, 0, "color(1, 0, 0)") orelse return error.TestExpectedEqual;
    try testing.expectEqual(gutterWidth(&ed) + 7 * 8 + ed.swatchWidth(), run.bounding_box.x);
    var swatches: usize = 0;
    for (drawn) |c| if (c.config == .rectangle and std.meta.eql(c.config.rectangle.color, Color.rgba(1, 0, 0, 1))) {
        swatches += 1;
    };
    try testing.expectEqual(@as(usize, 1), swatches);

    // A press on the swatch: the picker, and the caret where it was.
    const box = swatchBox(&ed, 7);
    const x = ed.view[0] + box[0] + box[2] / 2;
    const y = ed.view[1] + box[1] + ed.metrics.line_height / 2;
    ui.setPointer(x, y, true);
    _ = try frame(view, &ed, &ui, &ruler);
    view.pointer(&ed, &ui, .{ .x = x, .y = y, .down = true, .pressed = true, .mods = .{} });
    try testing.expect(ed.picking != null);
    try testing.expectEqual(@as(u32, 0), ed.buffer.cursor);
    ui.setPointer(x, y, false);
    _ = try frame(view, &ed, &ui, &ruler);
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expect(ui.boxOf(view.ids.picker) != null);

    // On the picker the view is not under the pointer, and its second
    // form's button writes the colour so.
    const form_button = ui.boxOf("code-picker-form-1") orelse return error.TestExpectedEqual;
    const bx = form_button.x + form_button.width / 2;
    const by = form_button.y + form_button.height / 2;
    ui.setPointer(bx, by, false);
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expect(!view.under(&ui));
    ui.setPointer(bx, by, true);
    _ = try frame(view, &ed, &ui, &ruler);
    ui.setPointer(bx, by, false);
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expectEqualStrings("tint = color(\"#FF0000\")\n", ed.buffer.text.items);
    try testing.expect(ed.picking != null);

    // Escape shuts it.
    try testing.expect(ed.cancel());
    try testing.expect(ed.picking == null);
}

test "the minimap is the code a pixel a character, drawn beside the scrollbar, and a press on it scrolls" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "ab c\n\td\n");
    for (0..200) |_| try text.appendSlice(gpa, "line\n");
    var ed: Document = try .init(gpa, "t.txt", text.items, languages.plain, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(gpa);
    const view: View = .{ .minimap_texture = 5 };
    const size = (try view.minimapPixels(&ed, gpa, &pixels)) orelse return error.TestExpectedEqual;
    try testing.expectEqual([2]u32{ minimap_columns, 203 * 2 }, size);
    const ink = [4]u8{ byte(Theme.dark.ink.r), byte(Theme.dark.ink.g), byte(Theme.dark.ink.b), 200 };
    const at = struct {
        fn at(p: []const u8, x: usize, y: usize) [4]u8 {
            return p[(y * minimap_columns + x) * 4 ..][0..4].*;
        }
    }.at;
    try testing.expectEqual(ink, at(pixels.items, 0, 0));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, at(pixels.items, 2, 0));
    try testing.expectEqual(ink, at(pixels.items, 3, 0));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, at(pixels.items, 0, 1));
    // A tab reaches the next stop.
    try testing.expectEqual(ink, at(pixels.items, 4, 2));
    // Made again only for a new text.
    try testing.expect((try view.minimapPixels(&ed, gpa, &pixels)) == null);

    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    _ = try frame(view, &ed, &ui, &ruler);
    const drawn = try frame(view, &ed, &ui, &ruler);
    var images: usize = 0;
    for (drawn) |c| if (c.config == .image and c.config.image.texture == 5) {
        images += 1;
        try testing.expectEqual(ed.view[2] - ed.aside, c.bounding_box.x);
    };
    try testing.expectEqual(@as(usize, 1), images);
    // Its lines past the view's middle: a press there scrolls down.
    const x = ed.view[0] + ed.view[2] - ed.aside + 10;
    const y = ed.view[1] + 300;
    try testing.expectEqual(ui_lib.CursorShape.arrow, shapeAt(&ed, x));
    view.pointer(&ed, &ui, .{ .x = x, .y = y, .down = true, .pressed = true, .mods = .{} });
    try testing.expect(ed.top > 0);
    try testing.expectEqual(@as(u32, 0), ed.buffer.cursor);
}

test "a button after the path the caret is in asks for another" {
    const gpa = testing.allocator;
    var lang = languages.json;
    lang.paths = .{ .schemes = &.{"res://"} };
    var ed: Document = try .init(gpa, "t.json", "{\"a\": \"res://x.png\"}", lang, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    const view: View = .{};
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expect(ui.boxOf(view.ids.choose) == null);
    ed.buffer.moveTo(10, false);
    _ = try frame(view, &ed, &ui, &ruler);
    const box = ui.boxOf(view.ids.choose) orelse return error.TestExpectedEqual;
    const bx = box.x + box.width / 2;
    const by = box.y + box.height / 2;
    ui.setPointer(bx, by, false);
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expect(!view.under(&ui));
    ui.setPointer(bx, by, true);
    _ = try frame(view, &ed, &ui, &ruler);
    ui.setPointer(bx, by, false);
    _ = try frame(view, &ed, &ui, &ruler);
    try testing.expectEqual([2]u32{ 7, 18 }, ed.takeChoice().?);
}
