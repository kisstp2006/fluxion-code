// SPDX-License-Identifier: BSD-2-Clause

//! What a language tells the code editor about itself, as data: how its
//! text is coloured, commented and indented, which brackets close
//! themselves, and - when something knows the language more deeply, a
//! compiler - what it says of the text: its mistakes, its outline, what may
//! be typed at the caret, the signature of the call it is in, what a name is
//! and where it is declared.
//!
//! A `Language` is a value. A simple one is its word lists and nothing else;
//! one with a compiler behind it adds a `Service`, whose hooks are all
//! optional. A program keeps a table of them by what files they are for, and
//! a new kind of file is a new row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const colors = @import("colors.zig");

pub const Error = error{OutOfMemory};

/// What a piece of text is, for its colour. The first ones are code's; the
/// ones after `invalid` are prose's.
pub const Style = enum(u8) {
    plain,
    keyword,
    /// `if`, `return`, `while`: the words that change where the code goes.
    control,
    type,
    /// A type the text itself declares.
    declared_type,
    function,
    /// A function the language comes with.
    library_function,
    variable,
    parameter,
    property,
    constant,
    enum_member,
    signal,
    namespace,
    number,
    string,
    comment,
    doc_comment,
    operator,
    annotation,
    /// A JSON object's key.
    key,
    invalid,
    heading,
    emphasis,
    strong,
    link,
    /// Code in prose.
    code,
    quote,
    /// A list's bullet or number.
    list,
};

/// A run of the text in one style. Tokens are in order and do not overlap;
/// one may cross lines, a block comment does. What is between tokens is
/// `plain`.
pub const Token = struct {
    start: u32,
    len: u32,
    style: Style,
};

pub const Severity = enum { @"error", warning, note };

/// Something wrong with the text. `line` and `column` are the editor's to
/// fill in from `start`: a language need only say where.
pub const Problem = struct {
    start: u32,
    end: u32,
    severity: Severity = .@"error",
    message: []const u8,
    line: u32 = 0,
    column: u32 = 0,
};

/// What a completion, an outline row or a symbol is: the letter and colour
/// it is shown with.
pub const ItemKind = enum {
    variable,
    constant,
    parameter,
    function,
    method,
    field,
    property,
    signal,
    type,
    @"struct",
    @"enum",
    enum_member,
    module,
    keyword,
    annotation,
    /// A value a host offers inside quotes: an action's name, a path.
    value,
    /// A file or a folder, in a path.
    file,
    folder,
};

/// What accepting a completion does besides putting in its name.
pub const Call = enum {
    /// Nothing: it is not called.
    none,
    /// `()` after it, the caret after them: it takes no arguments.
    empty,
    /// `()` after it, the caret between them and its signature asked for.
    arguments,
};

pub const Item = struct {
    label: []const u8,
    kind: ItemKind,
    /// Its type, or how it is declared.
    detail: []const u8 = "",
    doc: ?[]const u8 = null,
    /// Offered first when lower.
    rank: u8 = 0,
    call: Call = .none,
    /// A colour to show in place of its kind: a colour's name, offered.
    swatch: ?[4]f32 = null,
};

pub const Completions = struct {
    items: []const Item,
    /// The word at the caret, which a completion replaces.
    start: u32,
    end: u32,
};

pub const Signature = struct {
    /// The signature as shown: `mix(a: vec4, b: vec4, t: float) vec4`.
    label: []const u8,
    /// Where each parameter is in `label`, as byte offsets.
    params: []const [2]u32,
    /// The parameter the caret is at.
    active: u32,
    doc: ?[]const u8 = null,
};

/// What a name is: its declaration as code, and what its doc says.
pub const Hover = struct {
    start: u32,
    end: u32,
    code: []const u8,
    doc: ?[]const u8 = null,
};

/// A row of the outline: what the text declares, members under what they
/// belong to.
pub const Symbol = struct {
    name: []const u8,
    kind: ItemKind,
    detail: []const u8 = "",
    /// Its name in the text.
    start: u32,
    end: u32,
    children: []const Symbol = &.{},
};

/// Where a name is declared: here, or in another file.
pub const Definition = struct {
    /// Null when it is in the text asked about.
    path: ?[]const u8 = null,
    start: u32,
    end: u32,
};

/// What a language's service says of the text as it is.
pub const Analysis = struct {
    /// The service's own, for `hover` and `definition` to read and `forget`
    /// to let go of; null when it keeps nothing.
    state: ?*anyopaque = null,
    /// Its colours, or null to colour by the language's `lexis`.
    tokens: ?[]const Token = null,
    problems: []const Problem = &.{},
    symbols: []const Symbol = &.{},
};

/// A compiler's knowledge of a language, as hooks. `context` is the
/// service's own and is handed to every hook. The `arena` a hook is given
/// holds what it returns; `gpa` is for what it makes and lets go of itself.
pub const Service = struct {
    context: ?*anyopaque = null,
    /// Once for every change of the text, at most once a frame.
    analyze: ?*const fn (context: ?*anyopaque, gpa: Allocator, arena: Allocator, path: []const u8, text: []const u8) Error!Analysis = null,
    /// Let go of an analysis's `state`.
    forget: ?*const fn (context: ?*anyopaque, state: *anyopaque) void = null,
    /// What may be typed at `offset`, or null for nothing.
    complete: ?*const fn (context: ?*anyopaque, gpa: Allocator, arena: Allocator, path: []const u8, text: []const u8, offset: u32) Error!?Completions = null,
    /// The call `offset` is among the arguments of.
    signature: ?*const fn (context: ?*anyopaque, gpa: Allocator, arena: Allocator, path: []const u8, text: []const u8, offset: u32) Error!?Signature = null,
    /// What the name at `offset` is, from the analysis of the text as it is.
    hover: ?*const fn (context: ?*anyopaque, state: ?*anyopaque, arena: Allocator, text: []const u8, offset: u32) Error!?Hover = null,
    /// Where the name at `offset` is declared, from the analysis of the text.
    definition: ?*const fn (context: ?*anyopaque, state: ?*anyopaque, arena: Allocator, offset: u32) Error!?Definition = null,
    /// Characters that ask for completions when typed, besides the start of
    /// a word: `.` for members.
    triggers: []const u8 = "",
};

/// What Tab puts in, and what a level of indentation is.
pub const Indent = union(enum) {
    spaces: u8,
    tabs,

    /// How many columns wide a level is.
    pub fn width(self: Indent) u8 {
        return switch (self) {
            .spaces => |n| @max(n, 1),
            .tabs => 4,
        };
    }
};

/// How a language is coloured without a compiler: words it knows, its
/// comments, strings and numbers.
pub const Lexis = struct {
    keywords: []const []const u8 = &.{},
    control: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    constants: []const []const u8 = &.{},
    builtins: []const []const u8 = &.{},
    /// What opens and closes a string. A backslash escapes the next
    /// character; a string ends at its line's end.
    quotes: []const u8 = "",
    numbers: bool = false,
    /// A lexer of the language's own, for what word lists cannot say - a
    /// heading, a key - used instead of all of the above.
    tokens: ?*const fn (arena: Allocator, text: []const u8) Error![]const Token = null,
};

/// What a host knows of the files a text names. A string that starts with
/// one of `schemes` - `"res://art/hero.png"` - is a path: typing it offers
/// what is in its folder, ctrl and a click asks for its file to be opened,
/// and a button after it asks for another to be chosen.
pub const Paths = struct {
    schemes: []const []const u8 = &.{},
    context: ?*anyopaque = null,
    /// What is in `folder` - `"res://art/"` - as `.file` and `.folder`
    /// items, a folder's name ending in `/`.
    list: ?*const fn (context: ?*anyopaque, arena: Allocator, folder: []const u8) Error![]const Item = null,
};

pub const Language = struct {
    /// Its name, as a program shows it: "Flux", "JSON".
    name: []const u8,
    lexis: Lexis = .{},
    /// What starts a comment to the end of the line, and what toggles one on
    /// the lines picked; null for a language with none.
    line_comment: ?[]const u8 = null,
    block_comment: ?[2][]const u8 = null,
    /// Opening characters and their closers: typing the one puts in both.
    pairs: []const [2]u8 = &.{},
    indent: Indent = .{ .spaces = 4 },
    /// A line ending in one of these is followed by one more level.
    indent_after: []const u8 = "",
    /// The ways it writes a colour, which the view puts a swatch before and
    /// a picker behind: see `colors`.
    colors: []const colors.Form = &.{},
    paths: Paths = .{},
    service: Service = .{},

    /// What an opening character closes with, or null.
    pub fn closerOf(self: *const Language, c: u8) ?u8 {
        for (self.pairs) |pair| if (pair[0] == c) return pair[1];
        return null;
    }

    pub fn isCloser(self: *const Language, c: u8) bool {
        for (self.pairs) |pair| if (pair[1] == c) return true;
        return false;
    }
};

test "a language says which characters close which" {
    const lang: Language = .{ .name = "t", .pairs = &.{ .{ '(', ')' }, .{ '"', '"' } } };
    try std.testing.expectEqual(@as(?u8, ')'), lang.closerOf('('));
    try std.testing.expectEqual(@as(?u8, null), lang.closerOf('['));
    try std.testing.expect(lang.isCloser('"'));
    try std.testing.expect(!lang.isCloser('('));
    try std.testing.expectEqual(@as(u8, 4), (Indent{ .tabs = {} }).width());
}
