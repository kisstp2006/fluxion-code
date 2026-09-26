# Fluxion Code

A code editor for [fluxion-ui](https://github.com/kisstp2006/fluxion-ui), for any language.

A language tells the editor what it knows about itself, as a value: its words, its comments, which brackets close themselves, what a level of indentation is - and, when a compiler stands behind it, what the compiler says of the text. The editor does the rest: the text and its undo, the caret and the selection, the keys and the mouse, colours, completions, signatures, hovers, going to a declaration, finding and replacing, and going to a line.

Plain text, Markdown and JSON come with it. A program adds its own languages and keeps a table of them by the files they are for, so a new kind of file is a new row.

## Pieces

| | What it is |
| --- | --- |
| `Language` | What a kind of file is: its `lexis`, its comments, its bracket pairs, its indentation and the characters after which a line indents, and its `service`. |
| `Lexis` | How it is coloured without a compiler: keywords, control words, types, constants, built-ins, quotes and numbers - or a lexer of its own for what word lists cannot say. |
| `Service` | A compiler's knowledge, as optional hooks: `analyze` (colours, problems, outline), `complete`, `signature`, `hover`, `definition`, and the characters that ask for completions. |
| `Document` | A file being edited: its `Buffer`, what its language said of it, the popups over it, the find bar and where it is scrolled. |
| `View` | A `Document` drawn with fluxion-ui, one row a line and only the rows in view, with the find bar above it. |
| `Theme` | The view's colours, and one for each `Style` a token can have. |
| `languages` | `plain`, `markdown` and `json`. |
| `search` | Finding words: the next place either way round, whole words, matching case, replacing them all. |
| `colors` | The ways a language writes a colour, finding the colours a text writes, and writing one back in any of those ways. |
| `commands` | What the code can be told to do, as data: each `Command` done in one place, and the menu a right click opens as a table of `Action` rows the program adds its own to. |

## A language

A language with no compiler is data:

```zig
const ini: code.Language = .{
    .name = "INI",
    .line_comment = ";",
    .pairs = &.{ .{ '[', ']' }, .{ '"', '"' } },
    .lexis = .{ .constants = &.{ "true", "false" }, .quotes = "\"", .numbers = true },
};
```

One with a compiler adds a service. Every hook is optional, and each is handed the service's own `context`:

```zig
const shading: code.Language = .{
    .name = "Shader",
    .line_comment = "//",
    .block_comment = .{ "/*", "*/" },
    .pairs = &.{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' } },
    .indent_after = "{([",
    .lexis = .{ .keywords = &.{ "uniform", "const" }, .types = &.{ "float", "vec2", "vec4" } },
    .service = .{
        .context = my_compiler,
        .analyze = analyze, // problems and colours, once a change
        .complete = complete, // what may be typed at the caret
        .signature = signature, // the call the caret is in
        .hover = hover, // what a name is
        .triggers = ".",
    },
};
```

`analyze` hands back an `Analysis`: its problems, its outline, and its colours - or none, for the lexis to colour it. What it keeps of the text for `hover` and `definition` it puts in `state`, and `forget` lets go of it. A language that comes with the editor gets more by copying it: `var json = code.languages.json; json.service = ...`.

### Colours

A language says how it writes a colour, and the view puts a swatch before each one it finds - not in a comment, and not in a string but its own. A press on the swatch opens fluxion-ui's `ColorPicker` under it: dragging it rewrites the colour where it is written, all of it one step to undo, and a button for each of the language's ways turns the colour into that one. A way that cannot write the colour - a name, for most colours - is greyed; while it is dragged, a named colour is written the first way that can.

```zig
const names = [_]code.colors.Name{ .{ .name = "red", .rgb = 0xFF0000 }, .{ .name = "royalblue", .rgb = 0x4169E1 } };
lang.colors = &.{
    .{ .channels = .{ .call = "color" } },                        // color(0.2, 0.4, 0.8[, 1.0])
    .{ .hex = .{ .call = "color" } },                              // color("#3366CC")
    .{ .hsv = .{ .call = "hsv" } },                                // hsv(220, 0.75, 0.8)
    .{ .named = .{ .call = "color", .names = &names } },           // color("royalblue")
    .{ .channels = .{ .call = "vec4", .least = 4, .unit_only = true } }, // a shader's vec4(1.0, 0.5, 0.0, 1.0)
    .{ .hex = .{} },                                               // "#3366CC", as JSON has it
};
```

A completion item with a `swatch` shows the colour in place of its kind's letter: a colour's name, offered.

### Paths

A host that knows its files gives a language `paths`. A string that starts with one of its `schemes` is a path: typing it offers what is in the folder it has got to, from `list` - a folder accepted, what is in it next - and ctrl and a click, or F12, asks for its file to be opened, as an `OpenRequest` of kind `named`. While the caret is in one, a button after it asks for another to be chosen: `takeChoice` hands the host where the path is, and `setPath` puts the one chosen there.

```zig
lang.paths = .{ .schemes = &.{ "res://", "user://" }, .context = project, .list = listFolder };

if (doc.takeChoice()) |at| {
    const chosen = try askForAFile(); // the host's own dialog
    try doc.setPath(at[0], chosen);
}
```

## A document and its view

```zig
var doc: code.Document = try .init(gpa, "notes.md", text, code.languages.markdown, .{
    .font_size = 14,
    .line_height = 20,
    .measure = ruler.measure(),
});
defer doc.deinit();

// The program's clipboard, for Cut, Copy and Paste.
doc.clipboard = .{ .context = app, .get = clipboardText, .set = setClipboardText, .has = hasClipboardText };

// Every frame: the keys and characters, the pointer, then the view.
_ = try doc.key(.enter, .{});
try doc.typeChar('a');
view.pointer(&doc, &ui, .{ .x = x, .y = y, .down = down, .pressed = pressed, .secondary = right_pressed, .mods = .{} });
if (wheel != 0 and view.under(&ui)) doc.scroll(wheel, shift);
doc.refresh();
view.draw(&doc, &ui, window_focused and view.hasKeys(&ui));
// ...and once the frame is laid out:
view.measure(&doc, &ui, 1);
```

**The minimap** is the code a pixel a character and two a line, in its colours, beside the scrollbar. The host makes a texture of it - `minimapPixels` hands back RGBA rows when the text changed since, with their size, and null when they are the text's - and gives the view its number in the renderer's table; a press or a drag on it scrolls there. With no texture, or no room, there is none.

```zig
if (try view.minimapPixels(&doc, gpa, &pixels)) |size| upload(texture, size, pixels.items);
view.minimap_texture = texture_number;
```

**The keyboard** is the code's once it is pressed, or given it with `view.focus(&ui)`, until something else takes fluxion-ui's focus: `view.hasKeys(&ui)` says whether it has it. It takes every key then, Tab too - the interface does not move the focus on from it, and fluxion-ui's `wantsKeyboard` is true - so a host hands it the keys and characters while `hasKeys`, and a field of its own, such as the find bar's, while `wantsKeyboard` and not `hasKeys`.

**A completion** may put in more than its name: an item's `insert` replaces from the list's `start` - which may be before the word, the `fn` of a method being written - with the caret at its `caret`. A word typed after one of the service's `triggers` asks again however long it is, so a list closed on the way opens.

`view.under(&ui)` says whether the pointer is on the view - its words, the rows and marks it lays over itself, a tooltip - rather than on the list of completions or on something else over it: where a press takes the keyboard and the wheel scrolls. The rows float, so fluxion-ui's `isPointerOver` of the view is false on them; ask `under`. A tooltip and a signature let the pointer through to the text beneath.

The text is kept as the file has it: its tabs stay tabs, drawn to the next stop, and `written` gives the text back with the file's own line breaks, `\r\n` or `\n`. `modified` says whether it changed since `markSaved`.

**Measured as it is drawn.** A `Ruler` measures the code at the interface's scale, where a font's size is a whole number of pixels, and back in the code's own pixels: at a scale that rounds the size - 14 at 1.25 is drawn at 18 - the caret and the selection stay on the characters to the end of a long line.

## Commands and the menu

Everything the code can be told to do is a `Command`, done in one place, `doc.perform(command)`, whether a key asked for it, the menu, or the program - an Edit menu of its own, say. `doc.can(command)` says whether it can be done just now: Cut and Copy with something selected and a clipboard, Undo with something to undo, Toggle comment in a language with line comments.

A right click opens a menu where it was pressed, the caret put there unless that is in the selection. The menu is a table: each `Action` row says what it is called, the keys that do the same, its group - to what the caret is on, run, change, clipboard, history, find, the file - and `when` it is there at all: always, with a selection, on a name the language can find the declaration of or say what it is, in a path, on a colour, in a language with comments. The groups come in that order with a line between, a row that cannot be done just now is greyed, and the menu keeps inside the window. Its own rows go to a declaration and say what a name is, open a path's file, pick a colour, comment, indent and unindent, duplicate, move and delete lines, change a selection's case, cut, copy, paste and select all, undo and redo, and find, replace and go to a line.

The program adds its rows with `view.actions`, each done by its own function, with `shows` to say whether it is there for this file and `can` whether it can be done now:

```zig
const run_in_game: code.Action = .{
    .label = "Run in the game",
    .group = .run,
    .when = .selection,
    .does = .{ .host = .{ .context = game, .run = runSelection, .shows = isScript, .can = gameRuns } },
};
view.actions = &.{run_in_game};
```

## Keys

| Keys | What they do |
| --- | --- |
| Arrows, Home, End, Page Up, Page Down, with Shift and Ctrl | Move, select, by words, to the ends |
| Enter, Tab, Shift+Tab | A new line indented as the language says; indent or unindent the lines picked |
| Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z | Undo, redo |
| Ctrl+X, Ctrl+C, Ctrl+V, Ctrl+A | Cut, copy, paste, select all |
| Ctrl+/ | Comment the lines picked, or uncomment them |
| Ctrl+Shift+D, Ctrl+Shift+K | Duplicate the lines picked, delete them |
| Alt+Up, Alt+Down | Move the lines picked up or down, one step to undo however far |
| Ctrl+Shift+U, Ctrl+U | The selection in upper case, in lower case |
| Ctrl+Space | Completions |
| F12, Ctrl+click | Go to the declaration, or open the file a path names |
| Ctrl+F, Ctrl+H, Ctrl+G | Find, replace, go to a line |
| F3, Shift+F3 | The next place, the one before |
| Right click | The menu, at the pointer |
| Escape | Close the menu, the lists and the colour picker over the code, then the find bar |

## In a program that has fluxion-ui already

Build `src/root.zig` over your own fluxion-ui and fluxion-text rather than this package's module, so that there is one `Ui` type:

```zig
const code_dep = b.dependency("fluxion_code", .{});
const code = b.createModule(.{
    .root_source_file = code_dep.path("src/root.zig"),
    .imports = &.{
        .{ .name = "fluxion_ui", .module = my_ui },
        .{ .name = "fluxion_text", .module = my_text },
    },
});
```

## License

BSD 2-Clause. See `LICENSE`.
