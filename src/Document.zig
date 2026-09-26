// SPDX-License-Identifier: BSD-2-Clause

//! A file open in the code editor, and what the keyboard and the mouse do to
//! it: the buffer, where the view is scrolled to, and what its language said
//! of the text - its colours, its mistakes, its outline - kept as of the
//! text's last change. Completions, signatures and hovers are asked for as
//! they are wanted, and finding and replacing words and going to a line are
//! here too.
//!
//! Nothing here draws, and nothing here knows a language: that is all the
//! `Language`'s. Widths come from the interface through `Metrics`, measured,
//! so any font will do; `View` is the view on fluxion-ui.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fuzzy = @import("fluxion_text").fuzzy;
const language_zig = @import("language.zig");
const lexis = @import("lexis.zig");
const search = @import("search.zig");
const Buffer = @import("Buffer.zig");
const colors_mod = @import("colors.zig");
const commands = @import("commands.zig");
const ColorPicker = @import("fluxion_ui").ColorPicker;
const Color = @import("fluxion_ui").Color;

const Language = language_zig.Language;
const Item = language_zig.Item;

const Document = @This();

pub const Metrics = struct {
    font_size: u16,
    line_height: f32,
    /// How wide a piece of the code is on screen, which only the interface
    /// knows: its font is its own, and its characters are not all of one
    /// width. Zero-width until the interface hands one over.
    measure: Measure = .{},
    /// How many spaces wide a tab is drawn.
    tab_width: u8 = 4,
};

/// How the code is measured, from the interface that draws it.
pub const Measure = struct {
    context: ?*const anyopaque = null,
    widthFn: ?*const fn (context: ?*const anyopaque, run: []const u8) f32 = null,

    pub fn width(self: Measure, run: []const u8) f32 {
        const f = self.widthFn orelse return 0;
        return f(self.context, run);
    }
};

pub const Key = enum { left, right, up, down, home, end, page_up, page_down, backspace, delete, enter, tab, escape, space, f3, f12, a, c, d, f, g, h, k, u, v, x, y, z, slash };

pub const Mods = struct { shift: bool = false, ctrl: bool = false, alt: bool = false };

/// The program's clipboard, for Cut, Copy and Paste: none, and they are
/// greyed. `get` hands over text that lasts until it is asked again, and is
/// asked only to paste; `has` says whether there is any to paste without
/// reading it, as a menu open for a while asks every frame.
pub const Clipboard = struct {
    context: ?*anyopaque = null,
    get: ?*const fn (context: ?*anyopaque) []const u8 = null,
    set: ?*const fn (context: ?*anyopaque, text: []const u8) void = null,
    has: ?*const fn (context: ?*anyopaque) bool = null,
};

/// The menu a right click opens, where it was opened: in the view's pixels,
/// from its top left.
pub const Menu = struct {
    open: bool = false,
    x: f32 = 0,
    y: f32 = 0,
};

pub const Completion = struct {
    open: bool = false,
    items: []const Item = &.{},
    /// Indexes into `items`: those matching what is typed, best first.
    shown: std.ArrayList(u32) = .empty,
    selected: usize = 0,
    /// The first of `shown` in the list's window.
    first: usize = 0,
    /// Where the word being completed starts.
    start: u32 = 0,
    /// What is in a path's folder: its names have dots and spaces in them,
    /// and end at a `/`.
    path: bool = false,
    arena: std.heap.ArenaAllocator,
};

pub const Hovering = struct {
    /// Where the pointer has rested, and since when.
    offset: ?u32 = null,
    since: f64 = 0,
    /// Shown at the caret, by `show_docs`: it stays, wherever the pointer
    /// rests, until something else is done.
    at_caret: bool = false,
    shown: ?language_zig.Hover = null,
    arena: std.heap.ArenaAllocator,
};

/// The bar over the code that finds words, replaces them, or goes to a line.
pub const Find = struct {
    pub const Mode = enum { find, replace, line };

    open: bool = false,
    mode: Mode = .find,
    query: std.ArrayList(u8) = .empty,
    replacement: std.ArrayList(u8) = .empty,
    options: search.Options = .{},
    /// Put the keyboard in the bar's field at the next frame, with what the
    /// query holds.
    focus: bool = false,
};

/// A file another hook asked to open: a declaration somewhere else, or the
/// file a path in the text names.
pub const OpenRequest = struct {
    path: []u8,
    start: u32,
    end: u32,
    /// `named`: a path in a string named it, to be opened for what it is -
    /// a picture, a scene - and not as code at a place.
    kind: enum { declaration, named } = .declaration,
};

gpa: Allocator,
buffer: Buffer,
/// Where it is saved.
path: []u8,
language: Language,
metrics: Metrics,

/// What the language's service keeps of its last analysis.
state: ?*anyopaque = null,
/// The buffer's version the analysis is of.
analyzed: u64 = 0,
/// What the view draws from the analysis, remade with it.
info: std.heap.ArenaAllocator,
tokens: []const language_zig.Token = &.{},
problems: []const language_zig.Problem = &.{},
symbols: []const language_zig.Symbol = &.{},
/// The colours written in it, in order, in the language's forms.
colors: []const colors_mod.Found = &.{},
/// The colour whose picker is open: where it is written, and the picker.
picking: ?Picking = null,
/// The path whose button was pressed, for the host to have another chosen:
/// where its text is, inside the quotes. See `takeChoice`.
choosing: ?[2]u32 = null,
/// The buffer's version the host's minimap is of, and its size in pixels;
/// see `View.minimapPixels`. A host drawing several documents' minimaps
/// from one texture sets it to 0 when it shows another.
minimap_of: u64 = 0,
minimap_size: [2]u32 = .{ 0, 0 },

/// The first line in view, and how far the view is scrolled sideways, in
/// pixels: a character is not a column when the font is not monospaced.
top: u32 = 0,
left: f32 = 0,
/// How many lines fit, from the view's size last frame.
rows: u32 = 30,
/// Keep the caret in view at the next frame.
reveal: bool = true,

completion: Completion,
signature: ?language_zig.Signature = null,
signature_arena: std.heap.ArenaAllocator,
hover: Hovering,
find: Find = .{},
menu: Menu = .{},
clipboard: Clipboard = .{},

/// Set by go to definition when the declaration is in another file.
open_request: ?OpenRequest = null,
/// The time, from the frame loop; the caret blinks against it.
now: f64 = 0,
typed_at: f64 = 0,

/// Where the view was drawn last frame: x, y, width, height.
view: [4]f32 = .{ 0, 0, 0, 0 },
/// How wide the line numbers were, from the view.
gutter: f32 = 0,
/// How wide what lies over the view's right side is - the minimap and the
/// scrollbar - which the caret is kept out from under.
aside: f32 = 0,
drag: enum { none, text, scrollbar, minimap } = .none,
/// How far the minimap was scrolled when it was pressed: it stays so while
/// it is dragged, so that a place on it stays a line.
minimap_from: f32 = 0,
last_click: f64 = -1,
clicks: u8 = 0,
click_offset: u32 = 0,

pub fn init(gpa: Allocator, path: []const u8, text: []const u8, lang: Language, metrics: Metrics) Allocator.Error!Document {
    var buffer: Buffer = try .init(gpa, text, .of(&lang));
    errdefer buffer.deinit();
    return .{
        .gpa = gpa,
        .buffer = buffer,
        .path = try gpa.dupe(u8, path),
        .language = lang,
        .metrics = metrics,
        .info = .init(gpa),
        .completion = .{ .arena = .init(gpa) },
        .signature_arena = .init(gpa),
        .hover = .{ .arena = .init(gpa) },
    };
}

pub fn deinit(ed: *Document) void {
    ed.forgetAnalysis();
    ed.info.deinit();
    ed.completion.shown.deinit(ed.gpa);
    ed.completion.arena.deinit();
    ed.signature_arena.deinit();
    ed.hover.arena.deinit();
    ed.find.query.deinit(ed.gpa);
    ed.find.replacement.deinit(ed.gpa);
    ed.buffer.deinit();
    ed.gpa.free(ed.path);
    ed.dropRequest();
}

/// Another file in the editor, as it is on disk.
pub fn load(ed: *Document, path: []const u8, text: []const u8) Allocator.Error!void {
    try ed.buffer.setText(text);
    ed.gpa.free(ed.path);
    ed.path = try ed.gpa.dupe(u8, path);
    ed.top = 0;
    ed.left = 0;
    ed.closePopups();
}

/// Another name for the file, as when it moved: what it is analysed as.
pub fn rename(ed: *Document, path: []const u8) Allocator.Error!void {
    const copy = try ed.gpa.dupe(u8, path);
    ed.gpa.free(ed.path);
    ed.path = copy;
    ed.analyzed = 0;
}

/// The text read as another language: its colours and what is said of it
/// again at the next `refresh`, its buffer typing by the new one's rules.
pub fn setLanguage(ed: *Document, lang: Language) void {
    ed.forgetAnalysis();
    ed.language = lang;
    ed.buffer.rules = .of(&lang);
    ed.analyzed = 0;
    ed.closePopups();
}

pub fn modified(ed: *const Document) bool {
    return ed.buffer.modified();
}

/// Say the text is what the file holds now: after it is written.
pub fn markSaved(ed: *Document) void {
    ed.buffer.saved = ed.buffer.version;
}

/// The text as the file should hold it, its own line breaks back. The
/// caller owns it.
pub fn written(ed: *const Document, gpa: Allocator) Allocator.Error![]u8 {
    return ed.buffer.written(gpa);
}

fn forgetAnalysis(ed: *Document) void {
    const state = ed.state orelse return;
    ed.state = null;
    if (ed.language.service.forget) |forget| forget(ed.language.service.context, state);
}

fn dropRequest(ed: *Document) void {
    if (ed.open_request) |r| ed.gpa.free(r.path);
    ed.open_request = null;
}

/// Take the file a hook asked to open, and where in it. The caller owns the
/// path.
pub fn takeRequest(ed: *Document) ?OpenRequest {
    const r = ed.open_request orelse return null;
    ed.open_request = null;
    return r;
}

// ---------------------------------------------------------------------------
// What the language says

/// Colours the text and asks the language's service about it again, if it
/// changed since it was last asked: once a frame at most, and never while
/// the keys come faster than that.
pub fn refresh(ed: *Document) void {
    if (ed.analyzed == ed.buffer.version) return;
    ed.analyzed = ed.buffer.version;
    ed.forgetAnalysis();
    _ = ed.info.reset(.retain_capacity);
    ed.tokens = &.{};
    ed.problems = &.{};
    ed.symbols = &.{};
    ed.colors = &.{};
    const arena = ed.info.allocator();
    const text = ed.buffer.text.items;
    const service = ed.language.service;
    var own: ?[]const language_zig.Token = null;
    if (service.analyze) |analyze| if (analyze(service.context, ed.gpa, arena, ed.path, text)) |said| {
        ed.state = said.state;
        own = said.tokens;
        ed.symbols = said.symbols;
        ed.problems = ed.placed(arena, said.problems) catch &.{};
    } else |_| {};
    ed.tokens = own orelse lexis.tokens(arena, &ed.language, text) catch &.{};
    ed.colors = colors_mod.find(arena, text, ed.language.colors, ed.tokens) catch &.{};
    // A colour picked is where it was written; one gone takes its picker.
    if (ed.picking) |p| if (ed.colorAt(p.start) == null) {
        ed.picking = null;
    };
}

pub const Picking = struct {
    start: u32,
    state: ColorPicker.State,
};

/// The colour written from `start`, if one is.
pub fn colorAt(ed: *const Document, start: u32) ?colors_mod.Found {
    const i = ed.firstColor(start);
    if (i < ed.colors.len and ed.colors[i].start == start) return ed.colors[i];
    return null;
}

/// The first colour that starts at `offset` or after it.
pub fn firstColor(ed: *const Document, offset: u32) usize {
    var lo: usize = 0;
    var hi = ed.colors.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (ed.colors[mid].start < offset) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// How wide the swatch before a colour is: room in the line.
pub fn swatchWidth(ed: *const Document) f32 {
    return @round(ed.metrics.line_height * 0.9);
}

/// How many swatches are in the line from `line_start` up to and at
/// `offset`: the room they take before it.
fn swatchesBefore(ed: *const Document, line_start: u32, offset: u32) f32 {
    if (ed.colors.len == 0) return 0;
    const from = ed.firstColor(line_start);
    const past = ed.firstColor(offset + 1);
    return @as(f32, @floatFromInt(past - from)) * ed.swatchWidth();
}

/// Open the picker of the colour written from `start`.
pub fn pickColor(ed: *Document, start: u32) void {
    const found = ed.colorAt(start) orelse return;
    ed.closePopups();
    ed.picking = .{ .start = start, .state = .init(found.color) };
    // What this picker does is a step of its own, not the last one's.
    ed.buffer.last = .none;
}

/// Write the colour from `start` as `c`: in the language's `form`, one undo
/// step each; or, when null, in the one it is in - or the first that can
/// write it, a name having none for most colours - all a picker's changes
/// one undo step. The caret stays where it was. Whether it could be written.
pub fn setColor(ed: *Document, start: u32, c: Color, form: ?u8) Allocator.Error!bool {
    ed.refresh();
    const found = ed.colorAt(start) orelse return false;
    const forms = ed.language.colors;
    const b = &ed.buffer;
    var buffer: [128]u8 = undefined;
    const was = b.text.items[found.start..found.end];
    const text = if (form) |which|
        (if (which < forms.len) colors_mod.write(&buffer, forms[which], c, was) else null) orelse return false
    else text: {
        if (found.form < forms.len) if (colors_mod.write(&buffer, forms[found.form], c, was)) |w| break :text w;
        for (forms) |f| if (colors_mod.write(&buffer, f, c, was)) |w| break :text w;
        return false;
    };
    if (std.mem.eql(u8, text, was)) return true;
    const cursor = b.cursor;
    const anchor = b.anchor;
    const grown: i64 = @as(i64, @intCast(text.len)) - @as(i64, @intCast(was.len));
    try b.replace(found.start, found.end, text, if (form == null) .picking else .other);
    b.cursor = shifted(cursor, found.end, grown);
    b.anchor = shifted(anchor, found.end, grown);
    ed.typed_at = ed.now;
    ed.refresh();
    return true;
}

/// An offset after a change that ends at `end` and grew by `grown`.
fn shifted(offset: u32, end: u32, grown: i64) u32 {
    if (offset < end) return offset;
    return @intCast(@max(0, @as(i64, offset) + grown));
}

/// Problems with their lines and columns, and inside the text.
fn placed(ed: *const Document, arena: Allocator, problems: []const language_zig.Problem) Allocator.Error![]const language_zig.Problem {
    const out = try arena.alloc(language_zig.Problem, problems.len);
    for (problems, out) |p, *q| {
        const start = @min(p.start, ed.buffer.len());
        q.* = p;
        q.start = start;
        q.end = @min(@max(p.end, start), ed.buffer.len());
        q.line = ed.buffer.lineOf(start);
        q.column = ed.buffer.column(start);
    }
    return out;
}

/// The first token that ends after `offset`.
pub fn firstToken(ed: *const Document, offset: u32) usize {
    var lo: usize = 0;
    var hi = ed.tokens.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (ed.tokens[mid].start + ed.tokens[mid].len <= offset) lo = mid + 1 else hi = mid;
    }
    return lo;
}

pub fn counts(ed: *const Document) struct { errors: usize, warnings: usize } {
    var e: usize = 0;
    var w: usize = 0;
    for (ed.problems) |p| switch (p.severity) {
        .@"error" => e += 1,
        .warning => w += 1,
        .note => {},
    };
    return .{ .errors = e, .warnings = w };
}

// ---------------------------------------------------------------------------
// Completion

/// Asks what could be typed at the caret, and opens the list if anything could.
pub fn complete(ed: *Document) void {
    ed.refresh();
    _ = ed.completion.arena.reset(.retain_capacity);
    ed.completion.path = false;
    if (ed.pathAt(ed.buffer.cursor)) |at| return ed.completePath(at);
    const service = ed.language.service;
    const ask = service.complete orelse return;
    const found = (ask(service.context, ed.gpa, ed.completion.arena.allocator(), ed.path, ed.buffer.text.items, ed.buffer.cursor) catch null) orelse return ed.closeCompletion();
    ed.completion.items = found.items;
    ed.completion.start = found.start;
    ed.completion.open = found.items.len > 0;
    ed.filter();
}

/// What is in the folder the path at the caret has got to, from the host.
fn completePath(ed: *Document, at: [2]u32) void {
    const paths = ed.language.paths;
    const list = paths.list orelse return ed.closeCompletion();
    const typed = ed.buffer.text.items[at[0]..ed.buffer.cursor];
    for (paths.schemes) |scheme| {
        if (std.mem.startsWith(u8, typed, scheme)) break;
    } else return ed.closeCompletion();
    const slash = std.mem.lastIndexOfScalar(u8, typed, '/') orelse return ed.closeCompletion();
    const items = list(paths.context, ed.completion.arena.allocator(), typed[0 .. slash + 1]) catch return ed.closeCompletion();
    ed.completion.items = items;
    ed.completion.start = at[0] + @as(u32, @intCast(slash)) + 1;
    ed.completion.path = true;
    ed.completion.open = items.len > 0;
    ed.filter();
}

/// Where the text of the string around `offset` is, inside its quotes, as
/// of the last `refresh`: a string still open at its line's end holds the
/// offset at its end.
pub fn stringAt(ed: *const Document, offset: u32) ?[2]u32 {
    const text = ed.buffer.text.items;
    const t = ed.firstToken(offset);
    // The token going on past `offset`, or one that ends at it.
    var i = if (t > 0) t - 1 else t;
    while (i <= t and i < ed.tokens.len) : (i += 1) {
        const token = ed.tokens[i];
        if (token.style != .string or token.start > offset) continue;
        var start = token.start;
        var end = token.start + token.len;
        if (end > text.len or end < offset) continue;
        const quote = text[start];
        var closed = false;
        if (quote == '"' or quote == '\'') {
            start += 1;
            if (end > start and text[end - 1] == quote) {
                end -= 1;
                closed = true;
            }
        }
        if (offset < start or offset > end) continue;
        if (closed and offset == token.start + token.len) continue;
        return .{ start, end };
    }
    return null;
}

/// The path in the string around `offset`: the string's text, when it
/// starts with one of the language's `paths.schemes`.
pub fn pathAt(ed: *const Document, offset: u32) ?[2]u32 {
    const at = ed.stringAt(offset) orelse return null;
    const text = ed.buffer.text.items[at[0]..at[1]];
    for (ed.language.paths.schemes) |scheme| if (std.mem.startsWith(u8, text, scheme)) return at;
    return null;
}

/// Take the path whose button was pressed: where its text is, for `setPath`
/// once the host has had another chosen.
pub fn takeChoice(ed: *Document) ?[2]u32 {
    const at = ed.choosing orelse return null;
    ed.choosing = null;
    return at;
}

/// The string whose text starts at `start` becomes `path`, a step to undo,
/// the caret after it; nothing, if no string starts there any more.
pub fn setPath(ed: *Document, start: u32, path: []const u8) Allocator.Error!void {
    ed.refresh();
    const at = ed.stringAt(start) orelse return;
    if (at[0] != start) return;
    try ed.buffer.replace(at[0], at[1], path, .other);
    ed.edited();
}

/// The items that match the word typed so far, best first: the service's
/// rank - locals before the rest - then how well they match.
pub fn filter(ed: *Document) void {
    const c = &ed.completion;
    if (!c.open) return;
    if (ed.buffer.cursor < c.start or ed.buffer.selection() != null) return ed.closeCompletion();
    // What the completion replaces may start before the word - a method's
    // `fn` - and the word is what is matched.
    const from = if (c.path) c.start else @max(c.start, ed.buffer.wordStart(ed.buffer.cursor));
    const typed = ed.buffer.text.items[from..ed.buffer.cursor];
    for (typed) |ch| if (!Buffer.isWordChar(ch) and !(c.path and inName(ch))) return ed.closeCompletion();
    c.shown.clearRetainingCapacity();
    for (c.items, 0..) |item, i| {
        if (fuzzy.score(typed, item.label, .{}) == null) continue;
        c.shown.append(ed.gpa, @intCast(i)) catch return;
    }
    const Order = struct {
        items: []const Item,
        typed: []const u8,
        fn less(o: @This(), x: u32, y: u32) bool {
            const a = o.items[x];
            const b = o.items[y];
            // A name typed out exactly comes first, then the service's rank.
            const ea = std.mem.eql(u8, a.label, o.typed);
            const eb = std.mem.eql(u8, b.label, o.typed);
            if (ea != eb) return ea;
            if (a.rank != b.rank) return a.rank < b.rank;
            const sa = fuzzy.score(o.typed, a.label, .{}) orelse 0;
            const sb = fuzzy.score(o.typed, b.label, .{}) orelse 0;
            if (sa != sb) return sa > sb;
            return std.mem.order(u8, a.label, b.label) == .lt;
        }
    };
    std.mem.sort(u32, c.shown.items, Order{ .items = c.items, .typed = typed }, Order.less);
    if (c.shown.items.len == 0 or (c.shown.items.len == 1 and std.mem.eql(u8, c.items[c.shown.items[0]].label, typed))) {
        return ed.closeCompletion();
    }
    c.selected = 0;
    c.first = 0;
}

/// Whether `c` can be in a file's name in a path.
fn inName(c: u8) bool {
    return switch (c) {
        '/', '\\', '"', '\'', '\n' => false,
        else => true,
    };
}

pub fn closeCompletion(ed: *Document) void {
    ed.completion.open = false;
    ed.completion.shown.clearRetainingCapacity();
}

pub fn selectedItem(ed: *const Document) ?Item {
    const c = &ed.completion;
    if (!c.open or c.selected >= c.shown.items.len) return null;
    return c.items[c.shown.items[c.selected]];
}

/// Puts the chosen completion in place of the word; what is called gets its
/// parentheses, the caret between them when it takes arguments.
pub fn accept(ed: *Document, index: usize) Allocator.Error!void {
    const c = &ed.completion;
    if (index >= c.shown.items.len) return;
    const item = c.items[c.shown.items[index]];
    const b = &ed.buffer;
    if (c.path) {
        // The name to the next `/`, and a folder's `/` with it; what is in
        // a folder next.
        const folder = std.mem.endsWith(u8, item.label, "/");
        const in = ed.stringAt(b.cursor) orelse [2]u32{ b.cursor, b.cursor };
        const after = b.text.items[b.cursor..in[1]];
        var end = b.cursor + @as(u32, @intCast(std.mem.indexOfScalar(u8, after, '/') orelse after.len));
        if (folder and end < in[1]) end += 1;
        try b.replace(c.start, end, item.label, .other);
        ed.closeCompletion();
        if (folder) ed.complete();
        return;
    }
    const end = b.wordEnd(b.cursor);
    if (item.insert) |text| {
        try b.replace(c.start, end, text, .other);
        if (item.caret) |caret| b.moveTo(c.start + caret, false);
        ed.closeCompletion();
        return;
    }
    const next: u8 = if (end < b.len()) b.text.items[end] else 0;
    if (item.call != .none and next != '(') {
        const text = try std.fmt.allocPrint(ed.gpa, "{s}()", .{item.label});
        defer ed.gpa.free(text);
        try b.replace(c.start, end, text, .other);
        ed.closeCompletion();
        if (item.call == .arguments) {
            b.moveTo(b.cursor - 1, false);
            ed.askSignature();
        }
        return;
    }
    try b.replace(c.start, end, item.label, .other);
    ed.closeCompletion();
}

// ---------------------------------------------------------------------------
// Signatures and hovers

pub fn askSignature(ed: *Document) void {
    const service = ed.language.service;
    const ask = service.signature orelse return;
    _ = ed.signature_arena.reset(.retain_capacity);
    ed.signature = ask(service.context, ed.gpa, ed.signature_arena.allocator(), ed.path, ed.buffer.text.items, ed.buffer.cursor) catch null;
}

/// The pointer has rested on `offset`: after a moment, what is there is shown.
pub fn rest(ed: *Document, offset: ?u32) void {
    const h = &ed.hover;
    if (h.at_caret) return;
    if (offset == null) {
        h.offset = null;
        h.shown = null;
        return;
    }
    if (h.shown) |s| if (offset.? >= s.start and offset.? <= s.end) return;
    if (h.offset == null or h.offset.? != offset.?) {
        h.offset = offset;
        h.since = ed.now;
        h.shown = null;
        return;
    }
    if (h.shown != null or ed.now - h.since < 0.45) return;
    const service = ed.language.service;
    const ask = service.hover orelse return;
    if (ed.analyzed != ed.buffer.version) return;
    _ = h.arena.reset(.retain_capacity);
    // What the arena holds stays as long as it is shown, whatever becomes
    // of the analysis.
    h.shown = (ask(service.context, ed.state, h.arena.allocator(), ed.buffer.text.items, offset.?) catch return) orelse return;
}

pub fn closePopups(ed: *Document) void {
    ed.closeCompletion();
    ed.signature = null;
    ed.hover.shown = null;
    ed.hover.offset = null;
    ed.hover.at_caret = false;
    ed.picking = null;
    ed.menu.open = false;
}

/// Escape: what is open over the code closes, the lists first and then the
/// bar. Whether anything did.
pub fn cancel(ed: *Document) bool {
    if (ed.completion.open or ed.signature != null or ed.hover.shown != null or ed.picking != null or ed.menu.open) {
        ed.closePopups();
        return true;
    }
    if (ed.find.open) {
        ed.closeFind();
        return true;
    }
    return false;
}

/// Where the name at `at` is declared: here, the caret goes there; in
/// another file, that file is asked to be opened.
pub fn goToDefinition(ed: *Document, at: u32) void {
    ed.refresh();
    // A path names its file: that is asked to be opened.
    if (ed.pathAt(at)) |path| {
        ed.dropRequest();
        const copy = ed.gpa.dupe(u8, ed.buffer.text.items[path[0]..path[1]]) catch return;
        ed.open_request = .{ .path = copy, .start = 0, .end = 0, .kind = .named };
        return;
    }
    const service = ed.language.service;
    const ask = service.definition orelse return;
    ed.refresh();
    var arena: std.heap.ArenaAllocator = .init(ed.gpa);
    defer arena.deinit();
    const decl = (ask(service.context, ed.state, arena.allocator(), at) catch return) orelse return;
    if (decl.path) |path| {
        ed.dropRequest();
        const copy = ed.gpa.dupe(u8, path) catch return;
        ed.open_request = .{ .path = copy, .start = decl.start, .end = decl.end };
        return;
    }
    ed.select(decl.start, decl.end);
}

/// What the name at the caret is, shown there at once: what resting the
/// pointer on it shows after a moment.
pub fn showDocs(ed: *Document) void {
    const service = ed.language.service;
    const ask = service.hover orelse return;
    ed.refresh();
    const h = &ed.hover;
    _ = h.arena.reset(.retain_capacity);
    h.shown = (ask(service.context, ed.state, h.arena.allocator(), ed.buffer.text.items, ed.buffer.cursor) catch return) orelse return;
    h.offset = ed.buffer.cursor;
    h.at_caret = true;
}

// ---------------------------------------------------------------------------
// Commands, from a key, the menu or the program

/// Whether the caret is on a name: in it, or just after it.
fn onName(ed: *const Document) bool {
    const b = &ed.buffer;
    return b.wordStart(b.cursor) != b.wordEnd(b.cursor);
}

/// The colour the caret is on, by where it starts.
fn colorAtCaret(ed: *const Document) ?u32 {
    const at = ed.buffer.cursor;
    for (ed.colors) |found| {
        if (found.start > at) break;
        if (at <= found.end) return found.start;
    }
    return null;
}

/// Whether what a menu row asks of the caret and the file holds.
pub fn holds(ed: *const Document, when: commands.When) bool {
    const service = ed.language.service;
    return switch (when) {
        .always => true,
        .selection => ed.buffer.selection() != null,
        .definition => service.definition != null and ed.onName(),
        .docs => service.hover != null and ed.onName(),
        .path => ed.pathAt(ed.buffer.cursor) != null,
        .color => ed.colorAtCaret() != null,
        .comments => ed.language.line_comment != null,
    };
}

/// Whether `command` can be done just now.
pub fn can(ed: *const Document, command: commands.Command) bool {
    const b = &ed.buffer;
    return switch (command) {
        // F12 on a path opens its file, whatever the language knows.
        .go_to_definition => ed.holds(.definition) or ed.holds(.path),
        .show_docs => ed.holds(.docs),
        .open_path => ed.holds(.path),
        .pick_color => ed.holds(.color),
        .toggle_comment => ed.holds(.comments),
        .upper_case, .lower_case => b.selection() != null,
        .cut, .copy => b.selection() != null and ed.clipboard.set != null,
        .paste => ed.clipboard.get != null and if (ed.clipboard.has) |has| has(ed.clipboard.context) else true,
        .undo => b.canUndo(),
        .redo => b.canRedo(),
        .move_lines_up => b.selectedLines()[0] > 0,
        .move_lines_down => b.selectedLines()[1] + 1 < b.lineCount(),
        .indent, .unindent, .duplicate_lines, .delete_lines, .select_all, .find, .replace, .go_to_line => true,
    };
}

/// Do `command`, if it can be done: what its keys and its menu row do.
pub fn perform(ed: *Document, command: commands.Command) Allocator.Error!void {
    if (!ed.can(command)) return;
    const b = &ed.buffer;
    ed.menu.open = false;
    switch (command) {
        .go_to_definition, .open_path => return ed.goToDefinition(b.cursor),
        .show_docs => return ed.showDocs(),
        .pick_color => return ed.pickColor(ed.colorAtCaret().?),
        .select_all => return b.selectAll(),
        .find => return ed.openFind(.find),
        .replace => return ed.openFind(.replace),
        .go_to_line => return ed.openFind(.line),
        .copy => return ed.clipboard.set.?(ed.clipboard.context, b.selectedText()),
        .cut => {
            ed.clipboard.set.?(ed.clipboard.context, b.selectedText());
            try b.backspace();
        },
        .paste => {
            // A line break is one character here, however the clipboard
            // writes it.
            const clean = try std.mem.replaceOwned(u8, ed.gpa, ed.clipboard.get.?(ed.clipboard.context), "\r", "");
            defer ed.gpa.free(clean);
            if (clean.len == 0) return;
            try b.insert(clean);
        },
        .toggle_comment => try b.toggleComment(),
        .indent => try b.shiftLines(false),
        .unindent => try b.shiftLines(true),
        .duplicate_lines => try b.duplicateLines(),
        .move_lines_up => try b.moveLines(true),
        .move_lines_down => try b.moveLines(false),
        .delete_lines => try b.deleteLines(),
        .upper_case => try b.changeCase(true),
        .lower_case => try b.changeCase(false),
        .undo => try b.undo(),
        .redo => try b.redo(),
    }
    ed.edited();
}

/// The menu opened at (`x`, `y`) of the view, over whatever else was open.
pub fn openMenu(ed: *Document, x: f32, y: f32) void {
    ed.closePopups();
    ed.menu = .{ .open = true, .x = x, .y = y };
}

/// `start..end` picked, the caret at its end, and in view.
pub fn select(ed: *Document, start: u32, end: u32) void {
    ed.buffer.moveTo(start, false);
    ed.buffer.moveTo(end, true);
    ed.reveal = true;
}

// ---------------------------------------------------------------------------
// Finding and going to a line

/// The bar opened: to find, to replace, or to go to a line. A word picked
/// on one line is what it finds.
pub fn openFind(ed: *Document, mode: Find.Mode) void {
    ed.closePopups();
    ed.find.open = true;
    ed.find.mode = mode;
    ed.find.focus = true;
    if (mode == .line) return;
    const picked = ed.buffer.selectedText();
    if (picked.len > 0 and std.mem.indexOfScalar(u8, picked, '\n') == null) {
        ed.find.query.clearRetainingCapacity();
        ed.find.query.appendSlice(ed.gpa, picked) catch {};
    }
}

pub fn closeFind(ed: *Document) void {
    ed.find.open = false;
    ed.find.focus = false;
}

/// What is typed in the bar: the first place it is from where the
/// selection starts, found as it is typed.
pub fn setQuery(ed: *Document, query: []const u8) Allocator.Error!void {
    ed.find.query.clearRetainingCapacity();
    try ed.find.query.appendSlice(ed.gpa, query);
    if (query.len == 0) return;
    const from = if (ed.buffer.selection()) |s| s[0] else ed.buffer.cursor;
    if (search.next(ed.buffer.text.items, query, from, true, ed.find.options)) |found| ed.select(found[0], found[1]);
}

pub fn setReplacement(ed: *Document, with: []const u8) Allocator.Error!void {
    ed.find.replacement.clearRetainingCapacity();
    try ed.find.replacement.appendSlice(ed.gpa, with);
}

/// The next place the query is, or the one before: picked. Whether there
/// was one.
pub fn findNext(ed: *Document, forward: bool) bool {
    const b = &ed.buffer;
    const s = b.selection() orelse [2]u32{ b.cursor, b.cursor };
    const from = if (forward) s[1] else s[0];
    const found = search.next(b.text.items, ed.find.query.items, from, forward, ed.find.options) orelse return false;
    ed.select(found[0], found[1]);
    return true;
}

/// How many places the query is.
pub fn matches(ed: *const Document) usize {
    return search.count(ed.buffer.text.items, ed.find.query.items, ed.find.options);
}

/// The place picked replaced, if it is one of the query's, and the next one
/// picked.
pub fn replaceOne(ed: *Document) Allocator.Error!void {
    const b = &ed.buffer;
    if (b.selection()) |s| if (s[1] - s[0] == ed.find.query.items.len and search.isAt(b.text.items, ed.find.query.items, s[0], ed.find.options)) {
        try b.replace(s[0], s[1], ed.find.replacement.items, .other);
        ed.typed_at = ed.now;
    };
    _ = ed.findNext(true);
}

/// Every place replaced, as one step to undo. How many there were.
pub fn replaceAll(ed: *Document) Allocator.Error!usize {
    const b = &ed.buffer;
    const done = try search.replaceAll(ed.gpa, b.text.items, ed.find.query.items, ed.find.replacement.items, ed.find.options);
    defer ed.gpa.free(done.text);
    if (done.count == 0) return 0;
    const caret = b.cursor;
    try b.replace(0, b.len(), done.text, .other);
    b.moveTo(@min(caret, b.len()), false);
    ed.reveal = true;
    return done.count;
}

/// The caret to the start of a line, counted from one, and the bar shut.
pub fn goToLine(ed: *Document, line: u32) void {
    const b = &ed.buffer;
    const to = std.math.clamp(line, 1, b.lineCount()) - 1;
    b.moveTo(b.lineStart(to), false);
    ed.reveal = true;
    ed.closeFind();
}

// ---------------------------------------------------------------------------
// The keyboard

fn edited(ed: *Document) void {
    ed.reveal = true;
    ed.typed_at = ed.now;
    ed.hover.shown = null;
}

/// A character typed. Typing a name opens completions, as does one of the
/// service's `triggers`; `(` and `,` ask what the call takes.
pub fn typeChar(ed: *Document, codepoint: u21) Allocator.Error!void {
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(codepoint, &utf8) catch return;
    if (n == 1) try ed.buffer.typeChar(utf8[0]) else try ed.buffer.insert(utf8[0..n]);
    ed.edited();
    const c: u8 = if (n == 1) utf8[0] else 0;
    // In a path: what is in the folder it has got to.
    if (ed.language.paths.list != null) {
        ed.refresh();
        if (ed.pathAt(ed.buffer.cursor) != null) {
            if (ed.completion.open and ed.completion.path and c != '/') ed.filter() else ed.complete();
            return;
        }
    }
    const service = ed.language.service;
    if (Buffer.isWordChar(c)) {
        const start = ed.buffer.wordStart(ed.buffer.cursor);
        // A word's first letter asks, as does any after one of the
        // service's triggers, the list having been closed on the way.
        const after_trigger = start > 0 and std.mem.indexOfScalar(u8, service.triggers, ed.buffer.text.items[start - 1]) != null;
        if (ed.completion.open) {
            ed.filter();
        } else if (!std.ascii.isDigit(c) and (ed.buffer.cursor - start == 1 or after_trigger)) {
            ed.complete();
        }
    } else if (c != 0 and std.mem.indexOfScalar(u8, service.triggers, c) != null) {
        ed.complete();
    } else {
        ed.closeCompletion();
    }
    if (c == '(' or c == ',') ed.askSignature();
    if (c == ')') ed.signature = null;
}

/// A key pressed. Returns whether it did anything.
pub fn key(ed: *Document, k: Key, mods: Mods) Allocator.Error!bool {
    const b = &ed.buffer;
    const c = &ed.completion;
    // A key closes the menu, and does what it does.
    if (ed.menu.open) {
        ed.menu.open = false;
        if (k == .escape) return true;
    }
    if (c.open) switch (k) {
        .up, .down, .page_up, .page_down => {
            const count = c.shown.items.len;
            const step: i64 = switch (k) {
                .up => -1,
                .down => 1,
                .page_up => -8,
                else => 8,
            };
            const next = @as(i64, @intCast(c.selected)) + step;
            c.selected = @intCast(@mod(next, @as(i64, @intCast(count))));
            if (c.selected < c.first) c.first = c.selected;
            if (c.selected >= c.first + visible_items) c.first = c.selected + 1 - visible_items;
            return true;
        },
        .enter, .tab => {
            try ed.accept(c.selected);
            ed.edited();
            return true;
        },
        .escape => {
            ed.closeCompletion();
            return true;
        },
        else => {},
    };
    // The chords of commands, each done where the menu does it.
    if (commandOf(k, mods)) |command| {
        try ed.perform(command);
        return true;
    }
    switch (k) {
        .left => b.moveLeft(mods.shift, mods.ctrl),
        .right => b.moveRight(mods.shift, mods.ctrl),
        .up => b.vertical(-1, mods.shift),
        .down => b.vertical(1, mods.shift),
        .page_up => {
            b.vertical(-@as(i64, ed.rows), mods.shift);
            ed.top -|= ed.rows;
        },
        .page_down => {
            b.vertical(ed.rows, mods.shift);
            ed.top = @min(ed.top + ed.rows, b.lineCount() -| 1);
        },
        .home => if (mods.ctrl) b.moveTo(0, mods.shift) else b.moveHome(mods.shift),
        .end => if (mods.ctrl) b.moveTo(b.len(), mods.shift) else b.moveEnd(mods.shift),
        .backspace => {
            if (mods.ctrl) try b.deleteWord(false) else try b.backspace();
            ed.edited();
            ed.filter();
            if (ed.signature != null) ed.askSignature();
            return true;
        },
        .delete => {
            if (mods.ctrl) try b.deleteWord(true) else try b.delete();
            ed.edited();
            return true;
        },
        .enter => {
            try b.newline();
            ed.edited();
            ed.signature = null;
            return true;
        },
        .tab => {
            try b.tab();
            ed.edited();
            return true;
        },
        .escape => return ed.cancel(),
        .space => if (mods.ctrl) {
            ed.complete();
            return true;
        } else return false,
        .f3 => {
            _ = ed.findNext(!mods.shift);
            return true;
        },
        .f12, .a, .c, .d, .f, .g, .h, .k, .u, .v, .x, .y, .z, .slash => return false,
    }
    // The caret moved: the lists that were about where it was go, and what
    // was shown of the name it was on.
    ed.reveal = true;
    ed.closeCompletion();
    if (ed.hover.at_caret) {
        ed.hover.at_caret = false;
        ed.hover.shown = null;
    }
    if (ed.signature != null) ed.askSignature();
    return true;
}

/// The command a key and its modifiers are, if any: the keys `commands`
/// shows beside each row.
fn commandOf(k: Key, mods: Mods) ?commands.Command {
    if (mods.alt) return switch (k) {
        .up => .move_lines_up,
        .down => .move_lines_down,
        else => null,
    };
    if (k == .f12) return .go_to_definition;
    if (k == .tab and mods.shift) return .unindent;
    if (!mods.ctrl) return null;
    return switch (k) {
        .a => .select_all,
        .c => .copy,
        .x => .cut,
        .v => .paste,
        .f => .find,
        .h => .replace,
        .g => .go_to_line,
        .y => .redo,
        .z => if (mods.shift) .redo else .undo,
        .slash => .toggle_comment,
        .d => if (mods.shift) .duplicate_lines else null,
        .k => if (mods.shift) .delete_lines else null,
        .u => if (mods.shift) .upper_case else .lower_case,
        else => null,
    };
}

pub const visible_items = 10;

// ---------------------------------------------------------------------------
// The mouse, and places on screen

/// How wide the start of a line is, up to the end of `run`, which begins the
/// line: a tab reaches to the next stop.
pub fn widthOf(ed: *const Document, run: []const u8) f32 {
    const measure = ed.metrics.measure;
    if (std.mem.indexOfScalar(u8, run, '\t') == null) return measure.width(run);
    const stop = ed.tabStop();
    var x: f32 = 0;
    var rest_of = run;
    while (std.mem.indexOfScalar(u8, rest_of, '\t')) |i| {
        x += measure.width(rest_of[0..i]);
        x = (@floor(x / stop + 0.001) + 1) * stop;
        rest_of = rest_of[i + 1 ..];
    }
    return x + measure.width(rest_of);
}

/// How far apart the tab stops are, in pixels.
pub fn tabStop(ed: *const Document) f32 {
    return @max(1, ed.metrics.measure.width(" ")) * @as(f32, @floatFromInt(@max(ed.metrics.tab_width, 1)));
}

/// The offset under a point of the window, with the view where it was drawn
/// last and `gutter` its width.
pub fn offsetAt(ed: *const Document, view_x: f32, view_y: f32, gutter: f32, x: f32, y: f32) u32 {
    const m = ed.metrics;
    const row: i64 = @intFromFloat(@floor((y - view_y) / m.line_height));
    const line: u32 = @intCast(std.math.clamp(@as(i64, ed.top) + row, 0, @as(i64, ed.buffer.lineCount()) - 1));
    return ed.offsetInLine(line, x - view_x - gutter + ed.left);
}

/// The offset in `line` nearest `wanted` pixels from the line's start: each
/// character is measured until the pointer is past the middle of one.
pub fn offsetInLine(ed: *const Document, line: u32, wanted: f32) u32 {
    const b = &ed.buffer;
    const start = b.lineStart(line);
    const text = b.lineText(line);
    if (wanted <= 0) return start;
    var at: usize = 0;
    while (at < text.len) {
        const step = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
        const next = @min(text.len, at + step);
        // A swatch before the character is room of its own, to its left.
        const room = ed.swatchesBefore(start, start + @as(u32, @intCast(at)));
        const before = ed.widthOf(text[0..at]) + room;
        const after = ed.widthOf(text[0..next]) + room;
        if (wanted < (before + after) / 2) break;
        at = next;
    }
    return start + @as(u32, @intCast(at));
}

/// How far into the line `offset` is, in pixels.
pub fn xOf(ed: *const Document, offset: u32) f32 {
    const b = &ed.buffer;
    const line = b.lineOf(offset);
    const start = b.lineStart(line);
    const text = b.lineText(line);
    const upto = @min(text.len, offset - start);
    return ed.widthOf(text[0..upto]) + ed.swatchesBefore(start, offset);
}

/// The wheel, in notches: three lines each.
pub fn scroll(ed: *Document, notches: f32, sideways: bool) void {
    const lines: i64 = @intFromFloat(@round(-notches * 3));
    if (sideways) {
        ed.left = std.math.clamp(ed.left + @as(f32, @floatFromInt(lines)) * ed.metrics.line_height, 0, 8000);
    } else {
        const most: i64 = @max(0, @as(i64, ed.buffer.lineCount()) - 1);
        ed.top = @intCast(std.math.clamp(@as(i64, ed.top) + lines, 0, most));
    }
    ed.hover.shown = null;
}

/// Brings the caret into view, when a change or a key moved it.
pub fn follow(ed: *Document) void {
    if (!ed.reveal) return;
    // Not before the view has been measured once: there is no width yet to
    // keep the caret inside, and a guess scrolls the first frame sideways.
    if (ed.view[2] <= 0) return;
    ed.reveal = false;
    const b = &ed.buffer;
    const line = b.lineOf(b.cursor);
    if (line < ed.top) ed.top = line;
    if (ed.rows > 2 and line + 2 > ed.top + ed.rows) ed.top = line + 2 - ed.rows;

    // Sideways, in pixels, with a character's room either side of the caret.
    const room = ed.metrics.line_height;
    const x = ed.xOf(ed.buffer.cursor);
    const width = @max(64, ed.view[2] - ed.gutter - ed.aside);
    if (x < ed.left + room) ed.left = @max(0, x - room);
    if (x > ed.left + width - room) ed.left = x - width + room;
}

// ---------------------------------------------------------------------------
// Tests, with a toy language whose service is written here

const testing = std.testing;

/// Where the word going on from `from` ends.
fn wordEndIn(text: []const u8, from: usize) usize {
    var at = from;
    while (at < text.len and Buffer.isWordChar(text[at])) at += 1;
    return at;
}

/// `let name` declares a name; `fight(rounds, crit)` is a function the
/// language has; the word `bad` is a mistake. Its analysis keeps the text,
/// for its definitions.
const Toy = struct {
    fn toyAnalyze(_: ?*anyopaque, gpa: Allocator, arena: Allocator, _: []const u8, text: []const u8) language_zig.Error!language_zig.Analysis {
        var problems: std.ArrayList(language_zig.Problem) = .empty;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "bad")) |i| : (at = i + 3) {
            try problems.append(arena, .{ .start = @intCast(i), .end = @intCast(i + 3), .message = "bad is not allowed" });
        }
        const kept = try gpa.create([]u8);
        kept.* = try gpa.dupe(u8, text);
        return .{ .state = @ptrCast(kept), .problems = problems.items };
    }

    fn toyForget(_: ?*anyopaque, state: *anyopaque) void {
        const kept: *[]u8 = @ptrCast(@alignCast(state));
        testing.allocator.free(kept.*);
        testing.allocator.destroy(kept);
    }

    fn toyComplete(_: ?*anyopaque, _: Allocator, arena: Allocator, _: []const u8, text: []const u8, offset: u32) language_zig.Error!?language_zig.Completions {
        var items: std.ArrayList(Item) = .empty;
        var word = offset;
        while (word > 0 and Buffer.isWordChar(text[word - 1])) word -= 1;
        // After `fn `, a whole function; after a `@`, what may follow it.
        if (word >= 3 and std.mem.eql(u8, text[word - 3 .. word], "fn ")) {
            try items.append(arena, .{ .label = "go", .kind = .method, .insert = "fn go() {\n    \n}", .caret = 14 });
            return .{ .items = items.items, .start = word - 3, .end = offset };
        }
        if (word >= 1 and text[word - 1] == '@') {
            try items.append(arena, .{ .label = "export", .kind = .keyword });
            return .{ .items = items.items, .start = word, .end = offset };
        }
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "let ")) |i| : (at = i + 4) {
            const end = wordEndIn(text, i + 4);
            try items.append(arena, .{ .label = text[i + 4 .. end], .kind = .variable });
        }
        try items.append(arena, .{ .label = "fight", .kind = .function, .call = .arguments, .rank = 1 });
        var start = offset;
        while (start > 0 and Buffer.isWordChar(text[start - 1])) start -= 1;
        return .{ .items = items.items, .start = start, .end = offset };
    }

    fn toySignature(_: ?*anyopaque, _: Allocator, _: Allocator, _: []const u8, text: []const u8, offset: u32) language_zig.Error!?language_zig.Signature {
        const call = std.mem.lastIndexOf(u8, text[0..offset], "fight(") orelse return null;
        const commas = std.mem.count(u8, text[call..offset], ",");
        return .{ .label = "fight(rounds, crit)", .params = &.{ .{ 6, 12 }, .{ 14, 18 } }, .active = @intCast(commas) };
    }

    fn toyDefinition(_: ?*anyopaque, state: ?*anyopaque, _: Allocator, offset: u32) language_zig.Error!?language_zig.Definition {
        const kept: *[]u8 = @ptrCast(@alignCast(state orelse return null));
        const text = kept.*;
        var start = offset;
        while (start > 0 and Buffer.isWordChar(text[start - 1])) start -= 1;
        const word = text[start..wordEndIn(text, offset)];
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "let ")) |i| : (at = i + 4) {
            const end = wordEndIn(text, i + 4);
            if (std.mem.eql(u8, text[i + 4 .. end], word)) return .{ .start = @intCast(i + 4), .end = @intCast(end) };
        }
        return .{ .path = "elsewhere.toy", .start = 1, .end = 2 };
    }

    const lang: Language = .{
        .name = "Toy",
        .line_comment = "//",
        .pairs = &.{.{ '(', ')' }},
        .lexis = .{ .keywords = &.{"let"} },
        .service = .{ .analyze = toyAnalyze, .forget = toyForget, .complete = toyComplete, .signature = toySignature, .definition = toyDefinition, .triggers = "@" },
    };
};

const test_metrics: Metrics = .{ .font_size = 16, .line_height = 18 };

test "a completion may put in more than its name: a whole function, from its `fn`, the caret in its body" {
    var ed: Document = try .init(testing.allocator, "t.toy", "", Toy.lang, test_metrics);
    defer ed.deinit();
    for ("fn g") |c| try ed.typeChar(c);
    try testing.expect(ed.completion.open);
    try testing.expectEqualStrings("go", ed.selectedItem().?.label);
    try ed.accept(ed.completion.selected);
    try testing.expectEqualStrings("fn go() {\n    \n}", ed.buffer.text.items);
    try testing.expectEqual(@as(u32, 14), ed.buffer.cursor);
}

test "after a trigger, a word asks again however long it is: a list closed on the way opens" {
    var ed: Document = try .init(testing.allocator, "t.toy", "", Toy.lang, test_metrics);
    defer ed.deinit();
    try ed.buffer.insert("@e");
    try ed.typeChar('x');
    try testing.expect(ed.completion.open);
    try testing.expectEqualStrings("export", ed.selectedItem().?.label);
}

test "completions narrow as the word is typed, and a function comes with its parentheses and signature" {
    var ed: Document = try .init(testing.allocator, "t.toy", "let rounds\nlet robin\n", Toy.lang, test_metrics);
    defer ed.deinit();
    ed.buffer.moveTo(ed.buffer.len(), false);
    for ("rou") |c| try ed.typeChar(c);
    try testing.expect(ed.completion.open);
    try testing.expectEqualStrings("rounds", ed.selectedItem().?.label);
    try ed.accept(ed.completion.selected);
    try testing.expectEqualStrings("let rounds\nlet robin\nrounds", ed.buffer.text.items);

    try ed.typeChar(' ');
    for ("fig") |c| try ed.typeChar(c);
    try testing.expectEqualStrings("fight", ed.selectedItem().?.label);
    try ed.accept(ed.completion.selected);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.text.items, "fight()"));
    try testing.expectEqual(@as(u8, ')'), ed.buffer.text.items[ed.buffer.cursor]);
    try testing.expectEqual(@as(u32, 0), ed.signature.?.active);
    try ed.typeChar('1');
    try ed.typeChar(',');
    try testing.expectEqual(@as(u32, 1), ed.signature.?.active);
}

test "a mistake the service finds is placed at its line and column, and the words are coloured by the lexis" {
    var ed: Document = try .init(testing.allocator, "t.toy", "let a\n  bad\n", Toy.lang, test_metrics);
    defer ed.deinit();
    ed.refresh();
    try testing.expectEqual(@as(usize, 1), ed.problems.len);
    try testing.expectEqual(@as(u32, 1), ed.problems[0].line);
    try testing.expectEqual(@as(u32, 2), ed.problems[0].column);
    try testing.expectEqual(@as(usize, 1), ed.counts().errors);
    try testing.expectEqual(@as(usize, 1), ed.tokens.len);
    try testing.expectEqual(language_zig.Style.keyword, ed.tokens[0].style);
}

test "go to definition selects the name where it is declared, or asks for the file it is in" {
    var ed: Document = try .init(testing.allocator, "t.toy", "let ball\nball\nother\n", Toy.lang, test_metrics);
    defer ed.deinit();
    ed.goToDefinition(10);
    try testing.expectEqualStrings("ball", ed.buffer.selectedText());
    try testing.expectEqual(@as(u32, 0), ed.buffer.lineOf(ed.buffer.cursor));
    ed.goToDefinition(15);
    const request = ed.takeRequest().?;
    defer testing.allocator.free(request.path);
    try testing.expectEqualStrings("elsewhere.toy", request.path);
}

test "a language with no service is only coloured, and is typed by its own rules" {
    var ed: Document = try .init(testing.allocator, "notes.txt", "(", .{ .name = "Text" }, test_metrics);
    defer ed.deinit();
    ed.buffer.moveTo(1, false);
    try ed.typeChar('a');
    ed.complete();
    try testing.expect(!ed.completion.open);
    try testing.expectEqualStrings("(a", ed.buffer.text.items);
    ed.refresh();
    try testing.expectEqual(@as(usize, 0), ed.tokens.len);
    ed.setLanguage(Toy.lang);
    try ed.typeChar('(');
    try testing.expectEqualStrings("(a()", ed.buffer.text.items);
}

test "the bar finds the next place and round again, replaces one and all, and goes to a line" {
    var ed: Document = try .init(testing.allocator, "t.txt", "rock\nstone rock\nRock", .{ .name = "Text" }, test_metrics);
    defer ed.deinit();
    ed.buffer.moveTo(2, false);
    ed.openFind(.replace);
    try testing.expect(ed.find.open and ed.find.focus);
    try ed.setQuery("rock");
    try testing.expectEqual(@as(u32, 11), ed.buffer.selection().?[0]);
    try testing.expect(ed.findNext(true));
    try testing.expectEqual(@as(u32, 16), ed.buffer.selection().?[0]);
    try testing.expect(ed.findNext(true));
    try testing.expectEqual(@as(u32, 0), ed.buffer.selection().?[0]);
    try testing.expectEqual(@as(usize, 3), ed.matches());

    try ed.setReplacement("pebble");
    try ed.replaceOne();
    try testing.expectEqualStrings("pebble\nstone rock\nRock", ed.buffer.text.items);
    try testing.expectEqual(@as(u32, 13), ed.buffer.selection().?[0]);
    try testing.expectEqual(@as(usize, 2), try ed.replaceAll());
    try testing.expectEqualStrings("pebble\nstone pebble\npebble", ed.buffer.text.items);
    try ed.buffer.undo();
    try testing.expectEqualStrings("pebble\nstone rock\nRock", ed.buffer.text.items);

    ed.openFind(.line);
    ed.goToLine(3);
    try testing.expectEqual(@as(u32, 2), ed.buffer.lineOf(ed.buffer.cursor));
    try testing.expect(!ed.find.open);
    ed.goToLine(99);
    try testing.expectEqual(@as(u32, 2), ed.buffer.lineOf(ed.buffer.cursor));
}

test "a word picked is what the bar finds, and Escape shuts the lists before the bar" {
    var ed: Document = try .init(testing.allocator, "t.toy", "let apple\napple\n", Toy.lang, test_metrics);
    defer ed.deinit();
    ed.select(4, 9);
    _ = try ed.key(.f, .{ .ctrl = true });
    try testing.expectEqualStrings("apple", ed.find.query.items);
    ed.buffer.moveTo(ed.buffer.len(), false);
    for ("ap") |c| try ed.typeChar(c);
    try testing.expect(ed.completion.open);
    try testing.expect(try ed.key(.escape, .{}));
    try testing.expect(!ed.completion.open and ed.find.open);
    try testing.expect(try ed.key(.escape, .{}));
    try testing.expect(!ed.find.open);
    try testing.expect(!try ed.key(.escape, .{}));
}

/// A font whose `i` is narrow and whose other letters are not: what a
/// proportional one does to columns.
fn narrowI(_: ?*const anyopaque, run: []const u8) f32 {
    var w: f32 = 0;
    for (run) |c| w += if (c == 'i') 4 else 10;
    return w;
}

test "places in a line are measured, not counted, in any font, and a tab reaches the next stop" {
    var ed: Document = try .init(testing.allocator, "t.txt", "iiii wide and wider\nx\n\tab\tc\n", .{ .name = "Text" }, .{ .font_size = 16, .line_height = 20, .measure = .{ .widthFn = narrowI } });
    defer ed.deinit();

    // Four narrow letters and a space are 26 pixels, not five columns' 50.
    try testing.expectEqual(@as(f32, 26), ed.xOf(5));
    try testing.expectEqual(@as(u32, 5), ed.offsetInLine(0, 26));
    // A point goes to the nearer side of the character under it.
    try testing.expectEqual(@as(u32, 1), ed.offsetInLine(0, 3));
    try testing.expectEqual(@as(u32, 0), ed.offsetInLine(0, 1));
    // Past the end is the end; before the start is the start.
    try testing.expectEqual(@as(u32, 19), ed.offsetInLine(0, 999));
    try testing.expectEqual(@as(u32, 20), ed.offsetInLine(1, -5));
    // Through the view: gutter 30, the view at (100, 50), the second line.
    try testing.expectEqual(@as(u32, 21), ed.offsetAt(100, 50, 30, 100 + 30 + 9, 50 + 25));

    // A space is ten pixels here, so a stop is forty: `\tab` puts `a` at 40,
    // and the tab after `ab` - at 60 - reaches 80.
    const line = ed.buffer.lineStart(2);
    try testing.expectEqual(@as(f32, 40), ed.xOf(line + 1));
    try testing.expectEqual(@as(f32, 80), ed.xOf(line + 4));
    try testing.expectEqual(line + 4, ed.offsetInLine(2, 78));

    // Scrolled sideways, the caret at the end of a long line is kept in view.
    ed.view = .{ 0, 0, 130, 100 };
    ed.gutter = 30;
    ed.buffer.moveTo(19, false);
    ed.reveal = true;
    ed.follow();
    try testing.expect(ed.left > 0);
    try testing.expect(ed.xOf(19) - ed.left <= 100);
}

test "a colour in the text is found, a picker writes it back as one step, and a form of the language's another" {
    const gpa = testing.allocator;
    const forms = [_]colors_mod.Form{
        .{ .channels = .{ .call = "color" } },
        .{ .hex = .{ .call = "color" } },
    };
    var lang = @import("languages.zig").plain;
    lang.colors = &forms;
    var ed: Document = try .init(gpa, "t.txt", "tint = color(1, 0, 0) // red\n", lang, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    try testing.expectEqual(@as(usize, 1), ed.colors.len);
    const start: u32 = 7;
    try testing.expectEqual(start, ed.colors[0].start);
    try testing.expectEqual(@as(u8, 0), ed.colors[0].form);

    // The caret after the comment's word, where it stays as the colour
    // before it grows.
    const red_at: u32 = @intCast(std.mem.indexOf(u8, ed.buffer.text.items, "red").?);
    ed.buffer.moveTo(red_at, false);
    ed.pickColor(start);
    try testing.expect(ed.picking != null);
    try testing.expect(try ed.setColor(start, .rgba(0, 1, 0, 1), null));
    try testing.expect(try ed.setColor(start, .rgba(0, 0, 1, 1), null));
    try testing.expectEqualStrings("tint = color(0.0, 0.0, 1.0) // red\n", ed.buffer.text.items);
    try testing.expectEqualStrings("red", ed.buffer.text.items[ed.buffer.cursor..][0..3]);
    try testing.expectEqual(@as(f32, 1), ed.colors[0].color.b);

    // Another form: a step of its own.
    try testing.expect(try ed.setColor(start, ed.colors[0].color, 1));
    try testing.expectEqualStrings("tint = color(\"#0000FF\") // red\n", ed.buffer.text.items);
    try testing.expectEqual(@as(u8, 1), ed.colors[0].form);
    try ed.buffer.undo();
    try testing.expectEqualStrings("tint = color(0.0, 0.0, 1.0) // red\n", ed.buffer.text.items);
    try ed.buffer.undo();
    try testing.expectEqualStrings("tint = color(1, 0, 0) // red\n", ed.buffer.text.items);
    ed.refresh();

    // The swatch takes room before the colour: the characters after it are
    // that much further in, and a point is read back to the same offset.
    ed.metrics.measure = .{ .widthFn = struct {
        fn width(_: ?*const anyopaque, run: []const u8) f32 {
            return @floatFromInt(run.len * 8);
        }
    }.width };
    try testing.expectEqual(@as(f32, 6 * 8), ed.xOf(6));
    try testing.expectEqual(@as(f32, 7 * 8) + ed.swatchWidth(), ed.xOf(start));
    try testing.expectEqual(start + 1, ed.offsetInLine(0, ed.xOf(start + 1)));
}

/// A project with `art/hero.png` and `main.flux`, as a host lists it.
fn toyList(_: ?*anyopaque, arena: Allocator, folder: []const u8) language_zig.Error![]const Item {
    var items: std.ArrayList(Item) = .empty;
    if (std.mem.eql(u8, folder, "res://")) {
        try items.append(arena, .{ .label = "art/", .kind = .folder });
        try items.append(arena, .{ .label = "main.flux", .kind = .file });
    } else if (std.mem.eql(u8, folder, "res://art/")) {
        try items.append(arena, .{ .label = "hero.png", .kind = .file });
    }
    return items.items;
}

test "a path in a string is completed from the host's folders, named for opening, and chosen anew" {
    const gpa = testing.allocator;
    var lang = @import("languages.zig").json;
    lang.paths = .{ .schemes = &.{"res://"}, .list = toyList };
    var ed: Document = try .init(gpa, "t.json", "{\"a\": \"\"}", lang, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.buffer.moveTo(7, false);
    for ("res://") |c| try ed.typeChar(c);
    // What is in the project's root.
    try testing.expect(ed.completion.open and ed.completion.path);
    try testing.expectEqual(@as(usize, 2), ed.completion.shown.items.len);
    try ed.typeChar('a');
    try testing.expectEqualStrings("art/", ed.selectedItem().?.label);
    // A folder accepted: what is in it next.
    _ = try ed.key(.enter, .{});
    try testing.expectEqualStrings("{\"a\": \"res://art/\"}", ed.buffer.text.items);
    try testing.expect(ed.completion.open);
    try testing.expectEqualStrings("hero.png", ed.selectedItem().?.label);
    _ = try ed.key(.enter, .{});
    try testing.expectEqualStrings("{\"a\": \"res://art/hero.png\"}", ed.buffer.text.items);
    try testing.expect(!ed.completion.open);

    // Ctrl and a click on it: its file, to open for what it is.
    ed.goToDefinition(12);
    const request = ed.takeRequest() orelse return error.TestExpectedEqual;
    defer gpa.free(request.path);
    try testing.expectEqualStrings("res://art/hero.png", request.path);
    try testing.expect(request.kind == .named);

    // Another chosen for it.
    const at = ed.pathAt(12) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u32, 7), at[0]);
    try ed.setPath(at[0], "res://main.flux");
    try testing.expectEqualStrings("{\"a\": \"res://main.flux\"}", ed.buffer.text.items);
    // A string with no scheme is no path, nor is a key.
    try testing.expect(ed.pathAt(2) == null);
}

test "the keys of commands do what the menu does: the clipboard, lines duplicated and moved" {
    var ed: Document = try .init(testing.allocator, "t.toy", "alpha\nbeta", Toy.lang, test_metrics);
    defer ed.deinit();
    ed.buffer.moveTo(0, false);
    ed.buffer.moveTo(5, true);
    // With no clipboard, cut, copy and paste cannot be done.
    try testing.expect(!ed.can(.copy));
    try testing.expect(!ed.can(.paste));

    const Board = struct {
        held: [64]u8 = undefined,
        len: usize = 0,
        fn get(context: ?*anyopaque) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.held[0..self.len];
        }
        fn set(context: ?*anyopaque, text: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memcpy(self.held[0..text.len], text);
            self.len = text.len;
        }
    };
    var board: Board = .{};
    ed.clipboard = .{ .context = &board, .get = Board.get, .set = Board.set };
    try testing.expect(try ed.key(.c, .{ .ctrl = true }));
    try testing.expectEqualStrings("alpha", board.held[0..board.len]);
    // Pasted with its line breaks as this text has them.
    Board.set(&board, "x\r\ny");
    ed.buffer.moveTo(ed.buffer.len(), false);
    _ = try ed.key(.v, .{ .ctrl = true });
    try testing.expectEqualStrings("alpha\nbetax\ny", ed.buffer.text.items);

    ed.buffer.moveTo(0, false);
    _ = try ed.key(.d, .{ .ctrl = true, .shift = true });
    try testing.expectEqualStrings("alpha\nalpha\nbetax\ny", ed.buffer.text.items);
    ed.buffer.moveTo(ed.buffer.lineStart(2), false);
    _ = try ed.key(.up, .{ .alt = true });
    try testing.expectEqualStrings("alpha\nbetax\nalpha\ny", ed.buffer.text.items);
    try testing.expectEqual(@as(u32, 1), ed.buffer.lineOf(ed.buffer.cursor));
    _ = try ed.key(.k, .{ .ctrl = true, .shift = true });
    try testing.expectEqualStrings("alpha\nalpha\ny", ed.buffer.text.items);

    // Nothing selected, nothing to change the case of; the key is taken.
    try testing.expect(!ed.can(.upper_case));
    try testing.expect(try ed.key(.u, .{ .ctrl = true, .shift = true }));
    try testing.expectEqualStrings("alpha\nalpha\ny", ed.buffer.text.items);
}
