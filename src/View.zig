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

pub const Ids = struct {
    code: []const u8 = "code",
    completion: []const u8 = "code-completion",
    completion_doc: []const u8 = "code-completion-doc",
    signature: []const u8 = "code-signature",
    hover: []const u8 = "code-hover",
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

/// The code view, and the find bar over it while it is open. `focused` is
/// whether the code has the keyboard, which is when the caret shows.
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
    });
    defer ui.close();
    ed.gutter = gutterWidth(ed);
    var line = ed.top;
    const last = @min(ed.buffer.lineCount(), ed.top + ed.rows + 1);
    while (line < last) : (line += 1) v.row(ed, ui, line);
    v.gutterColumn(ed, ui);
    v.found(ed, ui);
    v.selection(ed, ui);
    v.mistakes(ed, ui);
    if (focused and @mod(ed.now - ed.typed_at, 1.0) < 0.6) v.caret(ed, ui);
    scrollbar(ed, ui);
    v.completion(ed, ui);
    v.signature(ed, ui);
    v.hover(ed, ui);
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
        if (until > at) v.textRun(ed, ui, start, at, until, color);
        at = @max(until, at + 1);
        while (t < ed.tokens.len and ed.tokens[t].start + ed.tokens[t].len <= at) t += 1;
    }
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
        const letter, const color = v.theme.kind(item.kind);
        ui.text(letter, v.style(ed, color));
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
    const over_popup = ui.isPointerOver(v.ids.completion) or ui.isPointerOver(v.ids.completion_doc) or ui.isPointerOver(v.ids.signature) or ui.isPointerOver(v.ids.hover);
    const inside = p.x >= x0 and p.x < x0 + w and p.y >= y0 and p.y < y0 + h and !over_popup;
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
        .none => {},
    }
    if (!inside) {
        ed.rest(null);
        return;
    }
    if (p.pressed) {
        ed.closePopups();
        if (p.x >= x0 + w - 12 and ed.buffer.lineCount() > ed.rows) {
            ed.drag = .scrollbar;
            return;
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
