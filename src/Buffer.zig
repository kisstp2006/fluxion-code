// SPDX-License-Identifier: BSD-2-Clause

//! The text being edited: its bytes, where each line starts, the caret and
//! the other end of the selection, and the changes that can be undone.
//! Offsets are bytes; columns are characters. Typing a word is one undo, as
//! is deleting one, and anything else is one each.
//!
//! The text is kept as the file has it - its tabs, and its line breaks as
//! `\r\n` or `\n` - and written back the same: `written` puts the file's own
//! line break back. What brackets close themselves, what a level of
//! indentation is and what comments a line are the language's `Rules`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const language = @import("language.zig");

const Buffer = @This();

/// What the language says about typing: see `language.Language`.
pub const Rules = struct {
    pairs: []const [2]u8 = &.{},
    indent: language.Indent = .{ .spaces = 4 },
    indent_after: []const u8 = "",
    line_comment: ?[]const u8 = null,

    pub fn of(lang: *const language.Language) Rules {
        return .{ .pairs = lang.pairs, .indent = lang.indent, .indent_after = lang.indent_after, .line_comment = lang.line_comment };
    }

    fn closerOf(self: Rules, c: u8) ?u8 {
        for (self.pairs) |pair| if (pair[0] == c) return pair[1];
        return null;
    }

    fn isCloser(self: Rules, c: u8) bool {
        for (self.pairs) |pair| if (pair[1] == c) return true;
        return false;
    }

    fn opensBlock(self: Rules, c: u8) bool {
        return c != 0 and std.mem.indexOfScalar(u8, self.indent_after, c) != null;
    }
};

/// How the file breaks its lines.
pub const LineEnding = enum { lf, crlf };

gpa: Allocator,
rules: Rules = .{},
text: std.ArrayList(u8) = .empty,
line_ending: LineEnding = .lf,
/// Where each line starts.
lines: std.ArrayList(u32) = .empty,
cursor: u32 = 0,
/// The other end of the selection: the caret's own offset when nothing is
/// selected.
anchor: u32 = 0,
/// The column up and down keep to across shorter lines.
goal: ?u32 = null,
undos: std.ArrayList(State) = .empty,
redos: std.ArrayList(State) = .empty,
last: Change = .none,
/// Counts every change, so what was made from the text can tell it is old.
version: u64 = 0,
saved: u64 = 0,

const State = struct { text: []u8, cursor: u32, anchor: u32 };
/// What a change is, for the undo: changes of one kind in a row are one
/// step, but for `other`.
pub const Change = enum { none, typing, deleting, other, picking, moving };
const max_undo = 400;

pub fn init(gpa: Allocator, text: []const u8, rules: Rules) Allocator.Error!Buffer {
    var b: Buffer = .{ .gpa = gpa, .rules = rules };
    try b.setText(text);
    return b;
}

pub fn deinit(b: *Buffer) void {
    b.clearHistory();
    b.undos.deinit(b.gpa);
    b.redos.deinit(b.gpa);
    b.text.deinit(b.gpa);
    b.lines.deinit(b.gpa);
}

fn clearHistory(b: *Buffer) void {
    for (b.undos.items) |s| b.gpa.free(s.text);
    for (b.redos.items) |s| b.gpa.free(s.text);
    b.undos.clearRetainingCapacity();
    b.redos.clearRetainingCapacity();
}

/// New text, as a file just opened, and no history. Its line breaks are
/// kept as `\n`, and which the file used is remembered for `written`: the
/// more common of the two, when it has both.
pub fn setText(b: *Buffer, text: []const u8) Allocator.Error!void {
    b.clearHistory();
    b.text.clearRetainingCapacity();
    var crlf: usize = 0;
    var lf: usize = 0;
    for (text, 0..) |c, i| switch (c) {
        '\r' => if (i + 1 < text.len and text[i + 1] == '\n') {
            crlf += 1;
        } else try b.text.append(b.gpa, '\n'),
        '\n' => {
            if (i == 0 or text[i - 1] != '\r') lf += 1;
            try b.text.append(b.gpa, '\n');
        },
        else => try b.text.append(b.gpa, c),
    };
    b.line_ending = if (crlf > lf) .crlf else .lf;
    b.cursor = 0;
    b.anchor = 0;
    b.goal = null;
    b.last = .none;
    b.version += 1;
    b.saved = b.version;
    try b.reindex();
}

/// The text as the file has it: its own line breaks back. The caller owns it.
pub fn written(b: *const Buffer, gpa: Allocator) Allocator.Error![]u8 {
    if (b.line_ending == .lf) return gpa.dupe(u8, b.text.items);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, b.text.items.len + b.lineCount());
    for (b.text.items) |c| {
        if (c == '\n') out.appendAssumeCapacity('\r');
        out.appendAssumeCapacity(c);
    }
    return out.toOwnedSlice(gpa);
}

pub fn modified(b: *const Buffer) bool {
    return b.version != b.saved;
}

fn reindex(b: *Buffer) Allocator.Error!void {
    b.lines.clearRetainingCapacity();
    try b.lines.append(b.gpa, 0);
    for (b.text.items, 0..) |c, i| if (c == '\n') try b.lines.append(b.gpa, @intCast(i + 1));
}

// ---------------------------------------------------------------------------
// Lines and columns

pub fn len(b: *const Buffer) u32 {
    return @intCast(b.text.items.len);
}

pub fn lineCount(b: *const Buffer) u32 {
    return @intCast(b.lines.items.len);
}

pub fn lineStart(b: *const Buffer, line: u32) u32 {
    return b.lines.items[@min(line, b.lineCount() - 1)];
}

/// Where the line ends, before its `\n`.
pub fn lineEnd(b: *const Buffer, line: u32) u32 {
    if (line + 1 < b.lineCount()) return b.lines.items[line + 1] - 1;
    return b.len();
}

pub fn lineText(b: *const Buffer, line: u32) []const u8 {
    return b.text.items[b.lineStart(line)..b.lineEnd(line)];
}

pub fn lineOf(b: *const Buffer, offset: u32) u32 {
    var lo: usize = 0;
    var hi = b.lines.items.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (b.lines.items[mid] <= offset) lo = mid else hi = mid;
    }
    return @intCast(lo);
}

fn isContinuation(c: u8) bool {
    return c & 0xC0 == 0x80;
}

/// Characters from the start of its line.
pub fn column(b: *const Buffer, offset: u32) u32 {
    var n: u32 = 0;
    for (b.text.items[b.lineStart(b.lineOf(offset))..offset]) |c| {
        if (!isContinuation(c)) n += 1;
    }
    return n;
}

/// The offset of a column on a line, or the line's end if it is shorter.
pub fn offsetAt(b: *const Buffer, line: u32, col: u32) u32 {
    var at = b.lineStart(line);
    const end = b.lineEnd(line);
    var n: u32 = 0;
    while (at < end and n < col) {
        at += 1;
        while (at < end and isContinuation(b.text.items[at])) at += 1;
        n += 1;
    }
    return at;
}

/// The selection, start first, or null when there is none.
pub fn selection(b: *const Buffer) ?[2]u32 {
    if (b.cursor == b.anchor) return null;
    return .{ @min(b.cursor, b.anchor), @max(b.cursor, b.anchor) };
}

pub fn selectedText(b: *const Buffer) []const u8 {
    const s = b.selection() orelse return "";
    return b.text.items[s[0]..s[1]];
}

pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Where the word ending at `offset` starts.
pub fn wordStart(b: *const Buffer, offset: u32) u32 {
    var at = offset;
    while (at > 0 and isWordChar(b.text.items[at - 1])) at -= 1;
    return at;
}

pub fn wordEnd(b: *const Buffer, offset: u32) u32 {
    var at = offset;
    while (at < b.len() and isWordChar(b.text.items[at])) at += 1;
    return at;
}

/// The bytes of blank - spaces and tabs - a line starts with.
fn indentOf(b: *const Buffer, line: u32) u32 {
    var n: u32 = 0;
    for (b.lineText(line)) |c| {
        if (!isBlank(c)) break;
        n += 1;
    }
    return n;
}

/// One level of indentation, as the language writes it.
fn unit(b: *const Buffer) []const u8 {
    return switch (b.rules.indent) {
        .spaces => |n| ("        ")[0..@min(@max(n, 1), 8)],
        .tabs => "\t",
    };
}

// ---------------------------------------------------------------------------
// Changes

fn remember(b: *Buffer, kind: Change) Allocator.Error!void {
    b.goal = null;
    for (b.redos.items) |s| b.gpa.free(s.text);
    b.redos.clearRetainingCapacity();
    if (kind != .other and kind == b.last) return;
    b.last = kind;
    if (b.undos.items.len == max_undo) {
        b.gpa.free(b.undos.orderedRemove(0).text);
    }
    try b.undos.append(b.gpa, .{ .text = try b.gpa.dupe(u8, b.text.items), .cursor = b.cursor, .anchor = b.anchor });
}

/// `text[start..end]` becomes `bytes`, the caret after them.
pub fn replace(b: *Buffer, start: u32, end: u32, bytes: []const u8, kind: Change) Allocator.Error!void {
    try b.remember(kind);
    try b.text.replaceRange(b.gpa, start, end - start, bytes);
    b.cursor = start + @as(u32, @intCast(bytes.len));
    b.anchor = b.cursor;
    b.version += 1;
    try b.reindex();
}

/// Types `bytes` over the selection, or at the caret.
pub fn insert(b: *Buffer, bytes: []const u8) Allocator.Error!void {
    const s = b.selection() orelse [2]u32{ b.cursor, b.cursor };
    const word = bytes.len == 1 and isWordChar(bytes[0]) and b.selection() == null;
    try b.replace(s[0], s[1], bytes, if (word) .typing else .other);
}

/// Types a character, closing a bracket or a quote it opens, and stepping
/// over the closer when it is what comes next.
pub fn typeChar(b: *Buffer, c: u8) Allocator.Error!void {
    const next: u8 = if (b.cursor < b.len()) b.text.items[b.cursor] else 0;
    if (b.selection() == null and b.rules.isCloser(c) and next == c) {
        b.moveTo(b.cursor + 1, false);
        return;
    }
    if (b.rules.closerOf(c)) |closer| {
        const opens_here = next == 0 or isBlank(next) or next == '\n' or b.rules.isCloser(next) or next == ',' or next == ';';
        // A quote straight after a word closes a string rather than opening one.
        const after_word = c == closer and b.cursor > 0 and isWordChar(b.text.items[b.cursor - 1]);
        if (b.selection() == null and opens_here and !after_word) {
            try b.replace(b.cursor, b.cursor, &.{ c, closer }, .other);
            b.moveTo(b.cursor - 1, false);
            return;
        }
    }
    try b.insert(&.{c});
}

pub fn backspace(b: *Buffer) Allocator.Error!void {
    if (b.selection()) |s| return b.replace(s[0], s[1], "", .deleting);
    if (b.cursor == 0) return;
    const start = b.lineStart(b.lineOf(b.cursor));
    const before = b.text.items[start..b.cursor];
    // In an indentation of spaces, back to the stop before.
    if (b.rules.indent == .spaces and before.len > 0 and std.mem.trimStart(u8, before, " ").len == 0) {
        const width = b.rules.indent.width();
        const to = (before.len - 1) / width * width;
        return b.replace(start + @as(u32, @intCast(to)), b.cursor, "", .deleting);
    }
    // Between a pair it just opened: both go.
    const prev = b.text.items[b.cursor - 1];
    const next: u8 = if (b.cursor < b.len()) b.text.items[b.cursor] else 0;
    if (b.rules.closerOf(prev)) |closer| if (closer == next) {
        return b.replace(b.cursor - 1, b.cursor + 1, "", .deleting);
    };
    var at = b.cursor - 1;
    while (at > 0 and isContinuation(b.text.items[at])) at -= 1;
    try b.replace(at, b.cursor, "", .deleting);
}

pub fn delete(b: *Buffer) Allocator.Error!void {
    if (b.selection()) |s| return b.replace(s[0], s[1], "", .deleting);
    if (b.cursor >= b.len()) return;
    var at = b.cursor + 1;
    while (at < b.len() and isContinuation(b.text.items[at])) at += 1;
    try b.replace(b.cursor, at, "", .deleting);
}

pub fn deleteWord(b: *Buffer, forward: bool) Allocator.Error!void {
    if (b.selection() != null) return if (forward) b.delete() else b.backspace();
    const to = if (forward) b.wordRight(b.cursor) else b.wordLeft(b.cursor);
    try b.replace(@min(to, b.cursor), @max(to, b.cursor), "", .other);
}

/// A line break, and the indentation the next line wants: the line's own,
/// one more after what opens a block, and its closer moved down a line.
pub fn newline(b: *Buffer) Allocator.Error!void {
    const line = b.lineOf(b.cursor);
    const own = b.lineText(line)[0..b.indentOf(line)];
    const prev: u8 = if (b.cursor > b.lineStart(line)) b.text.items[b.cursor - 1] else 0;
    const next: u8 = if (b.cursor < b.len()) b.text.items[b.cursor] else 0;
    const opens = b.rules.opensBlock(prev);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(b.gpa);
    try bytes.append(b.gpa, '\n');
    try bytes.appendSlice(b.gpa, own);
    if (opens) try bytes.appendSlice(b.gpa, b.unit());
    const caret = bytes.items.len;
    if (opens and b.rules.closerOf(prev) == next) {
        try bytes.append(b.gpa, '\n');
        try bytes.appendSlice(b.gpa, own);
    }
    const s = b.selection() orelse [2]u32{ b.cursor, b.cursor };
    try b.replace(s[0], s[1], bytes.items, .other);
    b.moveTo(s[0] + @as(u32, @intCast(caret)), false);
}

/// Tab: to the next stop, or the selected lines indented.
pub fn tab(b: *Buffer) Allocator.Error!void {
    if (b.selection()) |s| if (b.lineOf(s[0]) != b.lineOf(s[1])) return b.shiftLines(false);
    switch (b.rules.indent) {
        .tabs => try b.insert("\t"),
        .spaces => {
            const width = b.rules.indent.width();
            const spaces = width - b.column(b.cursor) % width;
            try b.insert(("        ")[0..@min(spaces, 8)]);
        },
    }
}

/// The first and the last line the selection is on, or the caret's line:
/// a selection that ends at the start of a line leaves that line out.
pub fn selectedLines(b: *const Buffer) [2]u32 {
    const s = b.selection() orelse [2]u32{ b.cursor, b.cursor };
    const first = b.lineOf(s[0]);
    var last = b.lineOf(s[1]);
    if (last > first and s[1] == b.lineStart(last)) last -= 1;
    return .{ first, last };
}

/// The selected lines, or the caret's, moved a level right or left.
pub fn shiftLines(b: *Buffer, left: bool) Allocator.Error!void {
    const first, const last = b.selectedLines();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(b.gpa);
    var line = first;
    while (line <= last) : (line += 1) {
        const text = b.lineText(line);
        if (left) {
            var n: usize = 0;
            if (text.len > 0 and text[0] == '\t') {
                n = 1;
            } else while (n < text.len and n < b.rules.indent.width() and text[n] == ' ') n += 1;
            try out.appendSlice(b.gpa, text[n..]);
        } else {
            if (text.len > 0) try out.appendSlice(b.gpa, b.unit());
            try out.appendSlice(b.gpa, text);
        }
        if (line < last) try out.append(b.gpa, '\n');
    }
    const start = b.lineStart(first);
    try b.replace(start, b.lineEnd(last), out.items, .other);
    b.anchor = start;
    b.cursor = start + @as(u32, @intCast(out.items.len));
}

/// The language's comment put before the selected lines, or taken off when
/// each has one. Nothing for a language with no comments.
pub fn toggleComment(b: *Buffer) Allocator.Error!void {
    const mark = b.rules.line_comment orelse return;
    const first, const last = b.selectedLines();
    var all = true;
    var least: u32 = std.math.maxInt(u32);
    var line = first;
    while (line <= last) : (line += 1) {
        const text = b.lineText(line);
        if (std.mem.trim(u8, text, " \t").len == 0) continue;
        least = @min(least, b.indentOf(line));
        if (!std.mem.startsWith(u8, text[b.indentOf(line)..], mark)) all = false;
    }
    if (least == std.math.maxInt(u32)) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(b.gpa);
    line = first;
    while (line <= last) : (line += 1) {
        const text = b.lineText(line);
        if (std.mem.trim(u8, text, " \t").len == 0) {
            try out.appendSlice(b.gpa, text);
        } else if (all) {
            const at = b.indentOf(line);
            var rest = text[at + mark.len ..];
            if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            try out.appendSlice(b.gpa, text[0..at]);
            try out.appendSlice(b.gpa, rest);
        } else {
            try out.appendSlice(b.gpa, text[0..least]);
            try out.appendSlice(b.gpa, mark);
            try out.append(b.gpa, ' ');
            try out.appendSlice(b.gpa, text[least..]);
        }
        if (line < last) try out.append(b.gpa, '\n');
    }
    const start = b.lineStart(first);
    try b.replace(start, b.lineEnd(last), out.items, .other);
    b.anchor = start;
    b.cursor = start + @as(u32, @intCast(out.items.len));
}

/// The selected lines, or the caret's, written again under themselves; the
/// selection goes with the copy.
pub fn duplicateLines(b: *Buffer) Allocator.Error!void {
    const first, const last = b.selectedLines();
    const end = b.lineEnd(last);
    var copy: std.ArrayList(u8) = .empty;
    defer copy.deinit(b.gpa);
    try copy.append(b.gpa, '\n');
    try copy.appendSlice(b.gpa, b.text.items[b.lineStart(first)..end]);
    const cursor = b.cursor;
    const anchor = b.anchor;
    try b.replace(end, end, copy.items, .other);
    const added: u32 = @intCast(copy.items.len);
    b.cursor = cursor + added;
    b.anchor = anchor + added;
}

/// The selected lines, or the caret's, gone with their line breaks; the
/// caret at the start of the line that comes up in their place.
pub fn deleteLines(b: *Buffer) Allocator.Error!void {
    const first, const last = b.selectedLines();
    var start = b.lineStart(first);
    var end = b.lineEnd(last);
    if (last + 1 < b.lineCount()) {
        end += 1;
    } else if (first > 0) {
        // The last line takes the break before it, not a line after it.
        start -= 1;
    }
    try b.replace(start, end, "", .other);
    b.moveTo(b.lineStart(@min(first, b.lineCount() - 1)), false);
}

/// The selected lines, or the caret's, swapped with the line above them or
/// below, the selection going with them. Moves one after another are one
/// step to undo.
pub fn moveLines(b: *Buffer, up: bool) Allocator.Error!void {
    const first, const last = b.selectedLines();
    if (if (up) first == 0 else last + 1 >= b.lineCount()) return;
    const other = if (up) first - 1 else last + 1;
    const from = b.lineStart(@min(first, other));
    const to = b.lineEnd(@max(last, other));
    const block = b.text.items[b.lineStart(first)..b.lineEnd(last)];
    const passed = b.lineText(other);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(b.gpa);
    if (up) {
        try out.appendSlice(b.gpa, block);
        try out.append(b.gpa, '\n');
        try out.appendSlice(b.gpa, passed);
    } else {
        try out.appendSlice(b.gpa, passed);
        try out.append(b.gpa, '\n');
        try out.appendSlice(b.gpa, block);
    }
    const shift: u32 = @intCast(passed.len + 1);
    const cursor = if (up) b.cursor - shift else b.cursor + shift;
    const anchor = if (up) b.anchor - shift else b.anchor + shift;
    try b.replace(from, to, out.items, .moving);
    b.cursor = cursor;
    b.anchor = anchor;
}

/// The selection in upper case, or lower: its ASCII letters, the rest as
/// they are. The selection stays.
pub fn changeCase(b: *Buffer, upper: bool) Allocator.Error!void {
    const s = b.selection() orelse return;
    const changed = try b.gpa.dupe(u8, b.text.items[s[0]..s[1]]);
    defer b.gpa.free(changed);
    for (changed) |*c| c.* = if (upper) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
    const cursor = b.cursor;
    const anchor = b.anchor;
    try b.replace(s[0], s[1], changed, .other);
    b.cursor = cursor;
    b.anchor = anchor;
}

pub fn undo(b: *Buffer) Allocator.Error!void {
    try b.step(&b.undos, &b.redos);
}

pub fn redo(b: *Buffer) Allocator.Error!void {
    try b.step(&b.redos, &b.undos);
}

pub fn canUndo(b: *const Buffer) bool {
    return b.undos.items.len > 0;
}

pub fn canRedo(b: *const Buffer) bool {
    return b.redos.items.len > 0;
}

fn step(b: *Buffer, from: *std.ArrayList(State), to: *std.ArrayList(State)) Allocator.Error!void {
    const s = from.pop() orelse return;
    try to.append(b.gpa, .{ .text = try b.gpa.dupe(u8, b.text.items), .cursor = b.cursor, .anchor = b.anchor });
    b.text.clearRetainingCapacity();
    try b.text.appendSlice(b.gpa, s.text);
    b.gpa.free(s.text);
    b.cursor = @min(s.cursor, b.len());
    b.anchor = @min(s.anchor, b.len());
    b.last = .none;
    b.goal = null;
    b.version += 1;
    try b.reindex();
}

// ---------------------------------------------------------------------------
// Moving

/// The caret to `offset`; the selection grows to it when `select`.
pub fn moveTo(b: *Buffer, offset: u32, select: bool) void {
    b.cursor = @min(offset, b.len());
    if (!select) b.anchor = b.cursor;
    b.last = .none;
}

fn charLeft(b: *const Buffer, offset: u32) u32 {
    if (offset == 0) return 0;
    var at = offset - 1;
    while (at > 0 and isContinuation(b.text.items[at])) at -= 1;
    return at;
}

fn charRight(b: *const Buffer, offset: u32) u32 {
    if (offset >= b.len()) return b.len();
    var at = offset + 1;
    while (at < b.len() and isContinuation(b.text.items[at])) at += 1;
    return at;
}

fn wordLeft(b: *const Buffer, offset: u32) u32 {
    var at = offset;
    while (at > 0 and isBlank(b.text.items[at - 1])) at -= 1;
    if (at > 0 and isWordChar(b.text.items[at - 1])) return b.wordStart(at);
    return b.charLeft(at);
}

fn wordRight(b: *const Buffer, offset: u32) u32 {
    var at = offset;
    if (at < b.len() and isWordChar(b.text.items[at])) return b.wordEnd(at);
    at = b.charRight(at);
    while (at < b.len() and isBlank(b.text.items[at])) at += 1;
    return at;
}

pub fn moveLeft(b: *Buffer, select: bool, word: bool) void {
    b.goal = null;
    if (!select and !word) if (b.selection()) |s| return b.moveTo(s[0], false);
    b.moveTo(if (word) b.wordLeft(b.cursor) else b.charLeft(b.cursor), select);
}

pub fn moveRight(b: *Buffer, select: bool, word: bool) void {
    b.goal = null;
    if (!select and !word) if (b.selection()) |s| return b.moveTo(s[1], false);
    b.moveTo(if (word) b.wordRight(b.cursor) else b.charRight(b.cursor), select);
}

/// Up or down by `lines`, keeping to the column it started from.
pub fn vertical(b: *Buffer, lines: i64, select: bool) void {
    const line: i64 = b.lineOf(b.cursor);
    const goal = b.goal orelse b.column(b.cursor);
    const target = std.math.clamp(line + lines, 0, @as(i64, b.lineCount()) - 1);
    const to = if (line + lines < 0) 0 else if (line + lines >= b.lineCount()) b.len() else b.offsetAt(@intCast(target), goal);
    b.moveTo(to, select);
    b.goal = goal;
}

/// To the first character of the line after its indentation, or to the
/// very start when it is there already.
pub fn moveHome(b: *Buffer, select: bool) void {
    const line = b.lineOf(b.cursor);
    const first = b.lineStart(line) + b.indentOf(line);
    b.goal = null;
    b.moveTo(if (b.cursor == first) b.lineStart(line) else first, select);
}

pub fn moveEnd(b: *Buffer, select: bool) void {
    b.goal = null;
    b.moveTo(b.lineEnd(b.lineOf(b.cursor)), select);
}

pub fn selectAll(b: *Buffer) void {
    b.anchor = 0;
    b.cursor = b.len();
}

pub fn selectWordAt(b: *Buffer, offset: u32) void {
    const at = @min(offset, b.len());
    b.anchor = b.wordStart(at);
    b.cursor = b.wordEnd(at);
    if (b.anchor == b.cursor) b.cursor = b.charRight(at);
}

const testing = std.testing;

/// Braces, brackets and quotes that close themselves, `//` comments and four
/// spaces: a C-like language's rules.
const c_like: Rules = .{
    .pairs = &.{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' }, .{ '"', '"' } },
    .indent_after = "{([",
    .line_comment = "//",
};

fn expectText(b: *const Buffer, want: []const u8) !void {
    try testing.expectEqualStrings(want, b.text.items);
}

test "typing, and undoing a word at a time" {
    var b: Buffer = try .init(testing.allocator, "", c_like);
    defer b.deinit();
    for ("hello") |c| try b.typeChar(c);
    try b.typeChar(' ');
    for ("world") |c| try b.typeChar(c);
    try expectText(&b, "hello world");
    try b.undo();
    try expectText(&b, "hello ");
    try b.undo();
    try expectText(&b, "hello");
    try b.redo();
    try expectText(&b, "hello ");
}

test "brackets close themselves, and a closer is stepped over" {
    var b: Buffer = try .init(testing.allocator, "", c_like);
    defer b.deinit();
    try b.typeChar('f');
    try b.typeChar('(');
    try expectText(&b, "f()");
    try testing.expectEqual(@as(u32, 2), b.cursor);
    try b.typeChar('x');
    try b.typeChar(')');
    try expectText(&b, "f(x)");
    try testing.expectEqual(@as(u32, 4), b.cursor);
    try b.typeChar('(');
    try b.backspace();
    try expectText(&b, "f(x)");
}

test "a language with no pairs types what is typed" {
    var b: Buffer = try .init(testing.allocator, "", .{});
    defer b.deinit();
    for ("(a\"") |c| try b.typeChar(c);
    try expectText(&b, "(a\"");
}

test "a new line keeps the indentation, and opens a block" {
    var b: Buffer = try .init(testing.allocator, "    fn f() {}", c_like);
    defer b.deinit();
    b.moveTo(12, false);
    try b.newline();
    try expectText(&b, "    fn f() {\n        \n    }");
    try testing.expectEqual(@as(u32, 21), b.cursor);
    try b.backspace();
    try expectText(&b, "    fn f() {\n    \n    }");
}

test "a language indented with tabs keeps them, and a new line takes the line's own" {
    var rules = c_like;
    rules.indent = .tabs;
    var b: Buffer = try .init(testing.allocator, "\tif (a) {}", rules);
    defer b.deinit();
    b.moveTo(9, false);
    try b.newline();
    try expectText(&b, "\tif (a) {\n\t\t\n\t}");
    try b.tab();
    try expectText(&b, "\tif (a) {\n\t\t\t\n\t}");
    b.selectAll();
    try b.shiftLines(true);
    try expectText(&b, "if (a) {\n\t\t\n}");
}

test "lines are shifted and commented as a block" {
    var b: Buffer = try .init(testing.allocator, "a\n    b\nc", c_like);
    defer b.deinit();
    b.selectAll();
    try b.shiftLines(false);
    try expectText(&b, "    a\n        b\n    c");
    try b.shiftLines(true);
    try expectText(&b, "a\n    b\nc");
    b.selectAll();
    try b.toggleComment();
    try expectText(&b, "// a\n//     b\n// c");
    try b.toggleComment();
    try expectText(&b, "a\n    b\nc");
}

test "a language's own comment is toggled, and one with none leaves the lines" {
    var rules = c_like;
    rules.line_comment = "#";
    var b: Buffer = try .init(testing.allocator, "key = 1", rules);
    defer b.deinit();
    try b.toggleComment();
    try expectText(&b, "# key = 1");
    b.rules.line_comment = null;
    try b.toggleComment();
    try expectText(&b, "# key = 1");
}

test "up and down keep their column across a short line" {
    var b: Buffer = try .init(testing.allocator, "abcdef\nab\nabcdef", c_like);
    defer b.deinit();
    b.moveTo(5, false);
    b.vertical(1, false);
    try testing.expectEqual(@as(u32, 9), b.cursor);
    b.vertical(1, false);
    try testing.expectEqual(@as(u32, 15), b.cursor);
    try testing.expectEqual(@as(u32, 5), b.column(b.cursor));
}

test "columns count characters, not bytes, and a tab stays a tab" {
    var b: Buffer = try .init(testing.allocator, "\u{e9}t\u{e9}\tx", c_like);
    defer b.deinit();
    try expectText(&b, "\u{e9}t\u{e9}\tx");
    try testing.expectEqual(@as(u32, 3), b.column(5));
    try testing.expectEqual(@as(u32, 5), b.offsetAt(0, 3));
    b.moveTo(5, false);
    b.moveLeft(false, false);
    try testing.expectEqual(@as(u32, 3), b.cursor);
}

test "a file's line breaks are written back as it had them" {
    const gpa = testing.allocator;
    var b: Buffer = try .init(gpa, "one\r\ntwo\r\n", .{});
    defer b.deinit();
    try expectText(&b, "one\ntwo\n");
    try testing.expectEqual(LineEnding.crlf, b.line_ending);
    b.moveTo(3, false);
    try b.newline();
    const out = try b.written(gpa);
    defer gpa.free(out);
    try testing.expectEqualStrings("one\r\n\r\ntwo\r\n", out);

    var plain: Buffer = try .init(gpa, "a\nb\n", .{});
    defer plain.deinit();
    const same = try plain.written(gpa);
    defer gpa.free(same);
    try testing.expectEqualStrings("a\nb\n", same);
}

test "lines duplicated, moved and deleted, and a selection's case changed" {
    var b: Buffer = try .init(testing.allocator, "one\ntwo\nthree", c_like);
    defer b.deinit();
    b.moveTo(b.lineStart(1) + 1, false);
    try b.duplicateLines();
    try expectText(&b, "one\ntwo\ntwo\nthree");
    try testing.expectEqual(@as(u32, 2), b.lineOf(b.cursor));

    // Moved up twice, the caret going with it: one step to undo.
    try b.moveLines(true);
    try b.moveLines(true);
    try expectText(&b, "two\none\ntwo\nthree");
    try testing.expectEqual(@as(u32, 0), b.lineOf(b.cursor));
    try b.undo();
    try expectText(&b, "one\ntwo\ntwo\nthree");

    // The last line takes the break before it with it.
    b.moveTo(b.len(), false);
    try b.deleteLines();
    try expectText(&b, "one\ntwo\ntwo");
    b.moveTo(0, false);
    try b.deleteLines();
    try expectText(&b, "two\ntwo");

    b.moveTo(0, false);
    b.moveTo(3, true);
    try b.changeCase(true);
    try expectText(&b, "TWO\ntwo");
    try testing.expectEqualStrings("TWO", b.selectedText());
}
