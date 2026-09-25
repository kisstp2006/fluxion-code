// SPDX-License-Identifier: BSD-2-Clause

//! Colours from what a language says as data: its words, its comments, its
//! strings and its numbers. A language with no compiler behind it is
//! coloured this way, and so is one whose compiler has not said yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const language = @import("language.zig");

const Language = language.Language;
const Token = language.Token;
const Style = language.Style;

/// The text's tokens: the language's own lexer's when it has one, else what
/// its word lists, comments, quotes and numbers find.
pub fn tokens(arena: Allocator, lang: *const Language, text: []const u8) language.Error![]const Token {
    if (lang.lexis.tokens) |own| return own(arena, text);
    var out: std.ArrayList(Token) = .empty;
    const lexis = &lang.lexis;
    var at: usize = 0;
    while (at < text.len) {
        const c = text[at];
        if (lang.line_comment) |mark| if (mark.len > 0 and std.mem.startsWith(u8, text[at..], mark)) {
            const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
            try out.append(arena, span(at, end, .comment));
            at = end;
            continue;
        };
        if (lang.block_comment) |marks| if (marks[0].len > 0 and std.mem.startsWith(u8, text[at..], marks[0])) {
            const close = std.mem.indexOfPos(u8, text, at + marks[0].len, marks[1]);
            const end = if (close) |found| found + marks[1].len else text.len;
            try out.append(arena, span(at, end, .comment));
            at = end;
            continue;
        };
        if (std.mem.indexOfScalar(u8, lexis.quotes, c) != null) {
            const end = stringEnd(text, at);
            try out.append(arena, span(at, end, .string));
            at = end;
            continue;
        }
        if (lexis.numbers and (std.ascii.isDigit(c) or (c == '.' and at + 1 < text.len and std.ascii.isDigit(text[at + 1]))) and !afterWord(text, at)) {
            const end = numberEnd(text, at);
            try out.append(arena, span(at, end, .number));
            at = end;
            continue;
        }
        if (isWordStart(c)) {
            var end = at + 1;
            while (end < text.len and isWordChar(text[end])) end += 1;
            if (styleOf(lexis, text[at..end])) |style| try out.append(arena, span(at, end, style));
            at = end;
            continue;
        }
        at += 1;
    }
    return out.items;
}

fn span(start: usize, end: usize, style: Style) Token {
    return .{ .start = @intCast(start), .len = @intCast(end - start), .style = style };
}

/// What a word is by the language's lists, or null for a name of the text's.
pub fn styleOf(lexis: *const language.Lexis, word: []const u8) ?Style {
    if (has(lexis.control, word)) return .control;
    if (has(lexis.keywords, word)) return .keyword;
    if (has(lexis.types, word)) return .type;
    if (has(lexis.constants, word)) return .constant;
    if (has(lexis.builtins, word)) return .library_function;
    return null;
}

fn has(words: []const []const u8, word: []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn isWordStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn afterWord(text: []const u8, at: usize) bool {
    return at > 0 and isWordChar(text[at - 1]);
}

/// Where a string opened at `at` closes: after its closing quote, or at its
/// line's end when it has none.
pub fn stringEnd(text: []const u8, at: usize) usize {
    const quote = text[at];
    var end = at + 1;
    while (end < text.len) : (end += 1) {
        switch (text[end]) {
            '\\' => end += 1,
            '\n' => return end,
            else => if (text[end] == quote) return end + 1,
        }
    }
    return text.len;
}

/// Where a number starting at `at` ends: digits, a point, an exponent, a
/// base's letters and a suffix.
pub fn numberEnd(text: []const u8, at: usize) usize {
    var end = at;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_') continue;
        // The sign of an exponent: `1e-3`.
        if ((c == '-' or c == '+') and end > at and (text[end - 1] == 'e' or text[end - 1] == 'E') and !isHex(text[at..end])) continue;
        break;
    }
    return end;
}

fn isHex(number: []const u8) bool {
    return number.len > 1 and number[0] == '0' and (number[1] == 'x' or number[1] == 'X');
}

const testing = std.testing;

test "words are coloured by the language's lists, and comments, strings and numbers by its marks" {
    const lang: Language = .{
        .name = "t",
        .line_comment = "//",
        .block_comment = .{ "/*", "*/" },
        .lexis = .{
            .keywords = &.{"uniform"},
            .control = &.{"if"},
            .types = &.{"vec4"},
            .builtins = &.{"mix"},
            .constants = &.{"true"},
            .quotes = "\"",
            .numbers = true,
        },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "uniform vec4 tint; // the colour\nif (true) x = mix(a, 1.5e-3, \"s\\\"q\") /* two\nlines */ v2";
    const found = try tokens(arena.allocator(), &lang, text);
    const want = [_]struct { []const u8, Style }{
        .{ "uniform", .keyword },
        .{ "vec4", .type },
        .{ "// the colour", .comment },
        .{ "if", .control },
        .{ "true", .constant },
        .{ "mix", .library_function },
        .{ "1.5e-3", .number },
        .{ "\"s\\\"q\"", .string },
        .{ "/* two\nlines */", .comment },
    };
    try testing.expectEqual(want.len, found.len);
    for (want, found) |w, t| {
        try testing.expectEqualStrings(w[0], text[t.start..][0..t.len]);
        try testing.expectEqual(w[1], t.style);
    }
}

test "a string with no closing quote ends at its line" {
    const lang: Language = .{ .name = "t", .lexis = .{ .quotes = "'" } };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try tokens(arena.allocator(), &lang, "'open\nnext");
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 5), found[0].len);
}
