// SPDX-License-Identifier: BSD-2-Clause

//! The colours a code view draws with: the view's own, and one for each
//! `Style` a token can have. `dark` is a dark one; a program with colours of
//! its own starts from it and changes what it has - its popups', its
//! selection's - and keeps the code's.

const std = @import("std");
const ui = @import("fluxion_ui");
const language = @import("language.zig");

const Color = ui.Color;
const Style = language.Style;
const Theme = @This();

/// Behind the code, and the line numbers beside it.
code: Color,
gutter: Color,
current_line: Color,
selection: Color,
/// Behind every place the find bar's words are.
match: Color,
caret: Color,
line_number: Color,
line_number_current: Color,

/// Text that is not a token of its own, and quieter text.
ink: Color,
dim: Color,
faint: Color,

error_ink: Color,
warning_ink: Color,

/// The lists and tooltips over the code.
popup: Color,
popup_selected: Color,
hover: Color,
tooltip: Color,
border: Color,
/// The argument of a call the caret is in, in the signature over it, and a
/// switch of the find bar that is on.
accent: Color,
/// The find bar, and its fields.
bar: Color,
field: Color,

/// Each style's colour.
styles: std.EnumArray(Style, Color),

pub const dark: Theme = .{
    .code = .hex(0x1D2229),
    .gutter = .hex(0x1D2229),
    .current_line = .hex(0x252B34),
    .selection = .hexa(0x3E6CA870),
    .match = .hexa(0xFFC85740),
    .caret = .hex(0xE8E8EA),
    .line_number = .hex(0x5C6370),
    .line_number_current = .hex(0xABB2BF),

    .ink = .hex(0xCDCFD2),
    .dim = .hex(0x8A93A0),
    .faint = .hex(0x5C6370),

    .error_ink = .hex(0xFF6B6B),
    .warning_ink = .hex(0xFFC857),

    .popup = .hex(0x262C35),
    .popup_selected = .hex(0x33455F),
    .hover = .hex(0x3A4250),
    .tooltip = .hex(0x2A303A),
    .border = .hex(0x2E343D),
    .accent = .hex(0x5AA9FF),
    .bar = .hex(0x232830),
    .field = .hex(0x1A1E24),

    .styles = .init(.{
        .plain = .hex(0xCDCFD2),
        .keyword = .hex(0xFF7085),
        .control = .hex(0xFF7085),
        .type = .hex(0x8FFFDB),
        .declared_type = .hex(0xC7FFED),
        .function = .hex(0x57B3FF),
        .library_function = .hex(0x66E6FF),
        .variable = .hex(0xCDCFD2),
        .parameter = .hex(0xF0C9A0),
        .property = .hex(0xBCE0FF),
        .constant = .hex(0xD8DBE0),
        .enum_member = .hex(0xA3D0FF),
        .signal = .hex(0xE6A1FF),
        .namespace = .hex(0x8FFFDB),
        .number = .hex(0xA1FFE0),
        .string = .hex(0xFFEDA1),
        .comment = .hex(0x6F7782),
        .doc_comment = .hex(0x99B3CC),
        .operator = .hex(0xABC9FF),
        .annotation = .hex(0xFFB373),
        .key = .hex(0xBCE0FF),
        .invalid = .hex(0xFF6B6B),
        .heading = .hex(0x57B3FF),
        .emphasis = .hex(0xF0C9A0),
        .strong = .hex(0xFFB373),
        .link = .hex(0x5AA9FF),
        .code = .hex(0xA1FFE0),
        .quote = .hex(0x8A93A0),
        .list = .hex(0xFF7085),
    }),
};

/// The colour of a token of `style`.
pub fn style(t: *const Theme, s: Style) Color {
    return t.styles.get(s);
}

/// The letter and colour a completion, an outline row or a symbol shows its
/// kind with.
pub fn kind(t: *const Theme, k: language.ItemKind) struct { []const u8, Color } {
    return switch (k) {
        .variable, .parameter => .{ "v", t.ink },
        .constant => .{ "c", t.style(.constant) },
        .function => .{ "f", t.style(.function) },
        .method => .{ "m", t.style(.function) },
        .field, .property => .{ "p", t.style(.property) },
        .signal => .{ "s", t.style(.signal) },
        .@"struct" => .{ "S", t.style(.declared_type) },
        .@"enum" => .{ "E", t.style(.declared_type) },
        .enum_member => .{ "e", t.style(.enum_member) },
        .module => .{ "M", t.style(.type) },
        .type => .{ "T", t.style(.type) },
        .keyword => .{ "k", t.style(.keyword) },
        .annotation => .{ "@", t.style(.annotation) },
        .value => .{ "\"", t.style(.string) },
        .file => .{ "F", t.style(.string) },
        .folder => .{ "/", t.accent },
    };
}
