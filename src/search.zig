// SPDX-License-Identifier: BSD-2-Clause

//! Finding words in the text: the next place a query is, either way round
//! and round again from the end, and how many places there are.

const std = @import("std");

pub const Options = struct {
    /// `Rock` finds `Rock` and not `rock`.
    match_case: bool = false,
    /// `rock` finds `rock` and not `rocks`.
    whole_word: bool = false,
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether `query` is at `at` in `text`.
pub fn isAt(text: []const u8, query: []const u8, at: usize, options: Options) bool {
    if (query.len == 0 or at + query.len > text.len) return false;
    const here = text[at..][0..query.len];
    const same = if (options.match_case) std.mem.eql(u8, here, query) else std.ascii.eqlIgnoreCase(here, query);
    if (!same) return false;
    if (!options.whole_word) return true;
    const before_ok = at == 0 or !isWordChar(text[at - 1]);
    const after_ok = at + query.len == text.len or !isWordChar(text[at + query.len]);
    return before_ok and after_ok;
}

/// The next place `query` is after `from` - or before it, backwards - going
/// round from the other end when there is none that way: its start and end.
pub fn next(text: []const u8, query: []const u8, from: usize, forward: bool, options: Options) ?[2]u32 {
    if (query.len == 0 or query.len > text.len) return null;
    const last = text.len - query.len;
    const begin = @min(from, text.len);
    if (forward) {
        var at = begin;
        while (at <= last) : (at += 1) if (isAt(text, query, at, options)) return found(at, query);
        at = 0;
        while (at < @min(begin, last + 1)) : (at += 1) if (isAt(text, query, at, options)) return found(at, query);
    } else {
        var at = @min(begin, last + 1);
        while (at > 0) {
            at -= 1;
            if (isAt(text, query, at, options)) return found(at, query);
        }
        at = last + 1;
        while (at > begin) {
            at -= 1;
            if (isAt(text, query, at, options)) return found(at, query);
        }
    }
    return null;
}

fn found(at: usize, query: []const u8) [2]u32 {
    return .{ @intCast(at), @intCast(at + query.len) };
}

/// How many places `query` is, none overlapping.
pub fn count(text: []const u8, query: []const u8, options: Options) usize {
    if (query.len == 0) return 0;
    var n: usize = 0;
    var at: usize = 0;
    while (at + query.len <= text.len) {
        if (isAt(text, query, at, options)) {
            n += 1;
            at += query.len;
        } else at += 1;
    }
    return n;
}

/// The text with every place `query` is replaced, and how many there were.
/// The caller owns what comes back.
pub fn replaceAll(gpa: std.mem.Allocator, text: []const u8, query: []const u8, with: []const u8, options: Options) std.mem.Allocator.Error!struct { text: []u8, count: usize } {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var n: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        if (query.len > 0 and isAt(text, query, at, options)) {
            try out.appendSlice(gpa, with);
            at += query.len;
            n += 1;
        } else {
            try out.append(gpa, text[at]);
            at += 1;
        }
    }
    return .{ .text = try out.toOwnedSlice(gpa), .count = n };
}

const testing = std.testing;

test "the next place goes round from the end, and backwards from the start" {
    const text = "rock rocks Rock";
    try testing.expectEqual([2]u32{ 5, 9 }, next(text, "rock", 1, true, .{}).?);
    try testing.expectEqual([2]u32{ 11, 15 }, next(text, "rock", 6, true, .{}).?);
    try testing.expectEqual([2]u32{ 0, 4 }, next(text, "rock", 12, true, .{}).?);
    try testing.expectEqual([2]u32{ 11, 15 }, next(text, "rock", 0, false, .{}).?);
    try testing.expectEqual([2]u32{ 5, 9 }, next(text, "rock", 11, false, .{}).?);
    try testing.expectEqual(@as(?[2]u32, null), next(text, "stone", 0, true, .{}));
}

test "the case and the whole word are asked for" {
    const text = "rock rocks Rock";
    try testing.expectEqual(@as(usize, 3), count(text, "rock", .{}));
    try testing.expectEqual(@as(usize, 2), count(text, "rock", .{ .match_case = true }));
    try testing.expectEqual(@as(usize, 2), count(text, "rock", .{ .whole_word = true }));
    try testing.expectEqual([2]u32{ 11, 15 }, next(text, "Rock", 0, true, .{ .match_case = true }).?);
}

test "every place is replaced, and counted" {
    const gpa = testing.allocator;
    const done = try replaceAll(gpa, "a rock and a Rock", "rock", "stone", .{});
    defer gpa.free(done.text);
    try testing.expectEqualStrings("a stone and a stone", done.text);
    try testing.expectEqual(@as(usize, 2), done.count);
}
