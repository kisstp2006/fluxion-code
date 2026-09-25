// SPDX-License-Identifier: BSD-2-Clause

//! The languages that come with the editor, needing nothing but themselves:
//! plain text, Markdown and JSON. A program adds what it knows to them - a
//! JSON file's mistakes from its own parser, as a `Service` - by copying one
//! and setting what it adds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const language = @import("language.zig");
const lexis = @import("lexis.zig");

const Language = language.Language;
const Token = language.Token;
const Style = language.Style;

/// Words and nothing else: no colours, no brackets closing themselves.
pub const plain: Language = .{ .name = "Text" };

pub const markdown: Language = .{
    .name = "Markdown",
    .indent = .{ .spaces = 2 },
    .lexis = .{ .tokens = markdownTokens },
};

pub const json: Language = .{
    .name = "JSON",
    // Comments too: what a program reads them from - a settings file - may
    // take them.
    .line_comment = "//",
    .block_comment = .{ "/*", "*/" },
    .pairs = &.{ .{ '{', '}' }, .{ '[', ']' }, .{ '"', '"' } },
    .indent = .{ .spaces = 2 },
    .indent_after = "{[",
    .lexis = .{ .tokens = jsonTokens },
};

// ---------------------------------------------------------------------------
// JSON

/// Keys, strings, numbers, `true`, `false` and `null`, and comments.
fn jsonTokens(arena: Allocator, text: []const u8) language.Error![]const Token {
    var out: std.ArrayList(Token) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        const c = text[at];
        if (std.mem.startsWith(u8, text[at..], "//")) {
            const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
            try out.append(arena, span(at, end, .comment));
            at = end;
        } else if (std.mem.startsWith(u8, text[at..], "/*")) {
            const end = if (std.mem.indexOfPos(u8, text, at + 2, "*/")) |close| close + 2 else text.len;
            try out.append(arena, span(at, end, .comment));
            at = end;
        } else if (c == '"' or c == '\'') {
            const end = lexis.stringEnd(text, at);
            try out.append(arena, span(at, end, if (beforeColon(text, end)) .key else .string));
            at = end;
        } else if (std.ascii.isDigit(c) or ((c == '-' or c == '+') and at + 1 < text.len and std.ascii.isDigit(text[at + 1]))) {
            const end = lexis.numberEnd(text, at + 1);
            try out.append(arena, span(at, end, .number));
            at = end;
        } else if (std.ascii.isAlphabetic(c) or c == '_') {
            var end = at + 1;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
            const word = text[at..end];
            const constant = std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false") or std.mem.eql(u8, word, "null");
            // A name with no quotes before a colon is a key where the
            // reader takes one.
            if (constant) {
                try out.append(arena, span(at, end, .constant));
            } else if (beforeColon(text, end)) try out.append(arena, span(at, end, .key));
            at = end;
        } else at += 1;
    }
    return out.items;
}

fn beforeColon(text: []const u8, from: usize) bool {
    var at = from;
    while (at < text.len and (text[at] == ' ' or text[at] == '\t')) at += 1;
    return at < text.len and text[at] == ':';
}

// ---------------------------------------------------------------------------
// Markdown

/// Headings, quotes, list marks and fenced code by the line; code, strong,
/// emphasis and links inside a line.
fn markdownTokens(arena: Allocator, text: []const u8) language.Error![]const Token {
    var out: std.ArrayList(Token) = .empty;
    var fenced: ?u8 = null;
    var start: usize = 0;
    while (start <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = text[start..end];
        const lead = leading(line);
        const body = line[lead..];
        if (fenced) |mark| {
            if (line.len > 0) try out.append(arena, span(start, end, .code));
            if (std.mem.startsWith(u8, body, &.{ mark, mark, mark })) fenced = null;
        } else if (lead < 4 and (std.mem.startsWith(u8, body, "```") or std.mem.startsWith(u8, body, "~~~"))) {
            fenced = body[0];
            try out.append(arena, span(start, end, .code));
        } else if (lead < 4 and isHeading(body)) {
            try out.append(arena, span(start, end, .heading));
        } else if (lead < 4 and body.len > 0 and body[0] == '>') {
            try out.append(arena, span(start, end, .quote));
        } else {
            var from = start;
            if (listMark(body)) |mark| {
                try out.append(arena, span(start + lead, start + lead + mark, .list));
                from = start + lead + mark;
            }
            try inline_(arena, &out, text, from, end);
        }
        if (end == text.len) break;
        start = end + 1;
    }
    return out.items;
}

fn leading(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

fn isHeading(body: []const u8) bool {
    var n: usize = 0;
    while (n < body.len and body[n] == '#') n += 1;
    return n >= 1 and n <= 6 and (n == body.len or body[n] == ' ');
}

/// How long a list's mark and the space after it are: `- `, `* `, `+ `,
/// `12. `, `3) `.
fn listMark(body: []const u8) ?usize {
    if (body.len >= 2 and (body[0] == '-' or body[0] == '*' or body[0] == '+') and body[1] == ' ') return 2;
    var n: usize = 0;
    while (n < body.len and std.ascii.isDigit(body[n])) n += 1;
    if (n > 0 and n + 1 < body.len and (body[n] == '.' or body[n] == ')') and body[n + 1] == ' ') return n + 2;
    return null;
}

/// Code, strong, emphasis, links and HTML comments in `text[start..end]`.
fn inline_(arena: Allocator, out: *std.ArrayList(Token), text: []const u8, start: usize, end: usize) language.Error!void {
    var at = start;
    while (at < end) {
        const c = text[at];
        const rest = text[at..end];
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, text[0..end], at + 1, '`')) |close| {
                try out.append(arena, span(at, close + 1, .code));
                at = close + 1;
                continue;
            }
        } else if ((c == '*' or c == '_') and rest.len > 1 and rest[1] == c) {
            if (std.mem.indexOfPos(u8, text[0..end], at + 2, &.{ c, c })) |close| if (close > at + 2) {
                try out.append(arena, span(at, close + 2, .strong));
                at = close + 2;
                continue;
            };
        } else if ((c == '*' or c == '_') and rest.len > 1 and rest[1] != ' ' and !(c == '_' and at > 0 and std.ascii.isAlphanumeric(text[at - 1]))) {
            if (std.mem.indexOfScalarPos(u8, text[0..end], at + 1, c)) |close| if (close > at + 1 and text[close - 1] != ' ') {
                try out.append(arena, span(at, close + 1, .emphasis));
                at = close + 1;
                continue;
            };
        } else if (c == '[') {
            if (link(text[0..end], at)) |close| {
                try out.append(arena, span(at, close, .link));
                at = close;
                continue;
            }
        } else if (std.mem.startsWith(u8, rest, "<!--")) {
            const close = if (std.mem.indexOfPos(u8, text[0..end], at + 4, "-->")) |found| found + 3 else end;
            try out.append(arena, span(at, close, .comment));
            at = close;
            continue;
        } else if (c == '<' and (std.mem.startsWith(u8, rest, "<http://") or std.mem.startsWith(u8, rest, "<https://"))) {
            if (std.mem.indexOfScalarPos(u8, text[0..end], at, '>')) |close| {
                try out.append(arena, span(at, close + 1, .link));
                at = close + 1;
                continue;
            }
        }
        at += 1;
    }
}

/// Where `[words](target)` opened at `at` ends, after its `)`.
fn link(text: []const u8, at: usize) ?usize {
    const words = std.mem.indexOfScalarPos(u8, text, at + 1, ']') orelse return null;
    if (words + 1 >= text.len or text[words + 1] != '(') return null;
    const target = std.mem.indexOfScalarPos(u8, text, words + 2, ')') orelse return null;
    return target + 1;
}

fn span(start: usize, end: usize, style: Style) Token {
    return .{ .start = @intCast(start), .len = @intCast(end - start), .style = style };
}

const testing = std.testing;

fn expectTokens(lang: *const Language, text: []const u8, want: []const struct { []const u8, Style }) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try lexis.tokens(arena.allocator(), lang, text);
    try testing.expectEqual(want.len, found.len);
    for (want, found) |w, t| {
        try testing.expectEqualStrings(w[0], text[t.start..][0..t.len]);
        try testing.expectEqual(w[1], t.style);
    }
}

test "JSON's keys are told from its strings, and its words and numbers are coloured" {
    try expectTokens(&json, "{\n  \"name\": \"Rock\", // a comment\n  \"size\" : -1.5e3,\n  flag: true, \"none\": null\n}", &.{
        .{ "\"name\"", .key },
        .{ "\"Rock\"", .string },
        .{ "// a comment", .comment },
        .{ "\"size\"", .key },
        .{ "-1.5e3", .number },
        .{ "flag", .key },
        .{ "true", .constant },
        .{ "\"none\"", .key },
        .{ "null", .constant },
    });
}

test "Markdown's headings, lists, quotes and fenced code by the line, and what is inside a line" {
    try expectTokens(&markdown,
        \\# Title
        \\Some **strong** and *soft* words, `code`, and [a link](https://x.y).
        \\- one
        \\12. two
        \\> quoted
        \\```zig
        \\const a = 1;
        \\```
        \\snake_case stays
    , &.{
        .{ "# Title", .heading },
        .{ "**strong**", .strong },
        .{ "*soft*", .emphasis },
        .{ "`code`", .code },
        .{ "[a link](https://x.y)", .link },
        .{ "- ", .list },
        .{ "12. ", .list },
        .{ "> quoted", .quote },
        .{ "```zig", .code },
        .{ "const a = 1;", .code },
        .{ "```", .code },
    });
}

test "plain text has no colours" {
    try expectTokens(&plain, "if (x) { \"y\" } // z", &.{});
}
