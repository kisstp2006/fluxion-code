// SPDX-License-Identifier: BSD-2-Clause

//! What code can be told to do, as data. Each `Command` is done in one
//! place, `Document.perform`, whether a key asked for it, a row of the menu a
//! right click opens, or the program that shows the code. The menu is a
//! table of `Action` rows - what each says, the keys that do the same, the
//! group it is in and when it is there at all - and a program adds rows of
//! its own to it the same way, with `Action.Host`: running a selection
//! somewhere, opening the file elsewhere.

const std = @import("std");
const Document = @import("Document.zig");

pub const Command = enum {
    go_to_definition,
    open_path,
    pick_color,
    show_docs,
    toggle_comment,
    indent,
    unindent,
    duplicate_lines,
    move_lines_up,
    move_lines_down,
    delete_lines,
    upper_case,
    lower_case,
    cut,
    copy,
    paste,
    select_all,
    undo,
    redo,
    find,
    replace,
    go_to_line,
};

/// Where a row stands in the menu: the groups in this order, a line
/// between each two that have rows.
pub const Group = enum {
    /// To what the caret is on: its declaration, its file, its colour.
    navigation,
    /// The selection run somewhere, by the program.
    run,
    change,
    clipboard,
    history,
    find,
    /// The file itself, by the program: opened elsewhere, shown elsewhere.
    file,
};

/// When a row is in the menu at all. A row that is there but cannot be done
/// just now - Cut with nothing selected, Undo with nothing to undo - is
/// greyed rather than gone, so the menu keeps its shape.
pub const When = enum {
    always,
    /// Something is selected.
    selection,
    /// The language can say where a name is declared, and the caret is on a
    /// name.
    definition,
    /// The language can say what a name is, and the caret is on one.
    docs,
    /// The caret is in a path.
    path,
    /// The caret is on a colour.
    color,
    /// The language has line comments.
    comments,
};

pub const Action = struct {
    label: []const u8,
    /// The keys that do the same, shown beside it.
    keys: []const u8 = "",
    group: Group,
    when: When = .always,
    does: Does,

    pub const Does = union(enum) {
        command: Command,
        host: Host,
    };

    /// A row of the program's own.
    pub const Host = struct {
        context: ?*anyopaque = null,
        /// What it does. The program says itself what went wrong.
        run: *const fn (context: ?*anyopaque, ed: *Document) void,
        /// Whether it is in the menu for this file, beside `when`.
        shows: ?*const fn (context: ?*anyopaque, ed: *const Document) bool = null,
        /// Whether it can be done just now; greyed when not.
        can: ?*const fn (context: ?*anyopaque, ed: *const Document) bool = null,
    };

    /// Whether it is in the menu, the caret and the selection being where
    /// they are.
    pub fn shown(self: Action, ed: *const Document) bool {
        if (!ed.holds(self.when)) return false;
        return switch (self.does) {
            .command => true,
            .host => |host| if (host.shows) |shows| shows(host.context, ed) else true,
        };
    }

    /// Whether it can be done just now.
    pub fn enabled(self: Action, ed: *const Document) bool {
        return switch (self.does) {
            .command => |command| ed.can(command),
            .host => |host| if (host.can) |can| can(host.context, ed) else true,
        };
    }

    /// Done, if it can be.
    pub fn run(self: Action, ed: *Document) std.mem.Allocator.Error!void {
        if (!self.enabled(ed)) return;
        switch (self.does) {
            .command => |command| try ed.perform(command),
            .host => |host| host.run(host.context, ed),
        }
    }
};

/// The menu's own rows, in the order they are shown within their groups.
pub const builtin = [_]Action{
    .{ .label = "Go to definition", .keys = "F12", .group = .navigation, .when = .definition, .does = .{ .command = .go_to_definition } },
    .{ .label = "What it is", .group = .navigation, .when = .docs, .does = .{ .command = .show_docs } },
    .{ .label = "Open the file", .keys = "Ctrl+click", .group = .navigation, .when = .path, .does = .{ .command = .open_path } },
    .{ .label = "Pick the colour", .group = .navigation, .when = .color, .does = .{ .command = .pick_color } },
    .{ .label = "Toggle comment", .keys = "Ctrl+/", .group = .change, .when = .comments, .does = .{ .command = .toggle_comment } },
    .{ .label = "Indent", .keys = "Tab", .group = .change, .does = .{ .command = .indent } },
    .{ .label = "Unindent", .keys = "Shift+Tab", .group = .change, .does = .{ .command = .unindent } },
    .{ .label = "Duplicate lines", .keys = "Ctrl+Shift+D", .group = .change, .does = .{ .command = .duplicate_lines } },
    .{ .label = "Move lines up", .keys = "Alt+Up", .group = .change, .does = .{ .command = .move_lines_up } },
    .{ .label = "Move lines down", .keys = "Alt+Down", .group = .change, .does = .{ .command = .move_lines_down } },
    .{ .label = "Delete lines", .keys = "Ctrl+Shift+K", .group = .change, .does = .{ .command = .delete_lines } },
    .{ .label = "UPPER CASE", .keys = "Ctrl+Shift+U", .group = .change, .when = .selection, .does = .{ .command = .upper_case } },
    .{ .label = "lower case", .keys = "Ctrl+U", .group = .change, .when = .selection, .does = .{ .command = .lower_case } },
    .{ .label = "Cut", .keys = "Ctrl+X", .group = .clipboard, .does = .{ .command = .cut } },
    .{ .label = "Copy", .keys = "Ctrl+C", .group = .clipboard, .does = .{ .command = .copy } },
    .{ .label = "Paste", .keys = "Ctrl+V", .group = .clipboard, .does = .{ .command = .paste } },
    .{ .label = "Select all", .keys = "Ctrl+A", .group = .clipboard, .does = .{ .command = .select_all } },
    .{ .label = "Undo", .keys = "Ctrl+Z", .group = .history, .does = .{ .command = .undo } },
    .{ .label = "Redo", .keys = "Ctrl+Y", .group = .history, .does = .{ .command = .redo } },
    .{ .label = "Find", .keys = "Ctrl+F", .group = .find, .does = .{ .command = .find } },
    .{ .label = "Replace", .keys = "Ctrl+H", .group = .find, .does = .{ .command = .replace } },
    .{ .label = "Go to line", .keys = "Ctrl+G", .group = .find, .does = .{ .command = .go_to_line } },
};

/// The rows shown, `builtin` and then the program's `extra`, each group's
/// together in the groups' order: into `out`, a null between each two
/// groups for the line between them. As many as `out` holds.
pub fn arrange(ed: *const Document, extra: []const Action, out: []?Action) []?Action {
    var n: usize = 0;
    var any_before = false;
    for (std.enums.values(Group)) |group| {
        var any = false;
        for ([2][]const Action{ &builtin, extra }) |table| for (table) |action| {
            if (action.group != group or !action.shown(ed)) continue;
            if (!any and any_before) {
                if (n == out.len) return out[0..n];
                out[n] = null;
                n += 1;
            }
            if (n == out.len) return out[0..n];
            out[n] = action;
            n += 1;
            any = true;
        };
        any_before = any_before or any;
    }
    return out[0..n];
}

test "every command has a row of the menu" {
    for (std.enums.values(Command)) |command| {
        for (builtin) |action| {
            if (action.does == .command and action.does.command == command) break;
        } else return error.TestExpectedEqual;
    }
}
