// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Code - a code editor for fluxion-ui, for any language.
//!
//! A `Document` is a file being edited: its text and its undo, the caret,
//! the keys, and what its language says of the text. A `View` draws it with
//! fluxion-ui and takes the pointer. A `Language` is what the editor knows
//! of a kind of file, as a value: its words, comments, brackets and
//! indentation, and - when a compiler stands behind it - a `Service` whose
//! hooks say what is wrong, what may be typed, what a call takes, what a
//! name is and where it is declared.
//!
//! Plain text, Markdown and JSON come with it, in `languages`. A program
//! adds its own - a scripting language, a shading language - and keeps a
//! table of them by the files they are for.

const std = @import("std");

pub const language = @import("language.zig");
pub const lexis = @import("lexis.zig");
pub const languages = @import("languages.zig");
pub const search = @import("search.zig");
pub const colors = @import("colors.zig");
pub const Buffer = @import("Buffer.zig");
pub const Document = @import("Document.zig");
pub const View = @import("View.zig");
pub const Theme = @import("Theme.zig");

pub const Language = language.Language;
pub const Lexis = language.Lexis;
pub const Service = language.Service;
pub const Indent = language.Indent;
pub const Style = language.Style;
pub const Token = language.Token;
pub const Severity = language.Severity;
pub const Problem = language.Problem;
pub const ItemKind = language.ItemKind;
pub const Call = language.Call;
pub const Item = language.Item;
pub const Completions = language.Completions;
pub const Signature = language.Signature;
pub const Hover = language.Hover;
pub const Symbol = language.Symbol;
pub const Definition = language.Definition;
pub const Paths = language.Paths;
pub const Analysis = language.Analysis;
pub const Error = language.Error;

pub const Metrics = Document.Metrics;
pub const Measure = Document.Measure;
pub const Key = Document.Key;
pub const Mods = Document.Mods;
pub const OpenRequest = Document.OpenRequest;
pub const Ruler = View.Ruler;
pub const Pointer = View.Pointer;

test {
    std.testing.refAllDecls(@This());
    _ = language;
    _ = lexis;
    _ = languages;
    _ = search;
    _ = colors;
    _ = Buffer;
    _ = Document;
    _ = View;
    _ = Theme;
}
