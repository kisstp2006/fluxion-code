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

## A document and its view

```zig
var doc: code.Document = try .init(gpa, "notes.md", text, code.languages.markdown, .{
    .font_size = 14,
    .line_height = 20,
    .measure = ruler.measure(),
});
defer doc.deinit();

// Every frame: the keys and characters, the pointer, then the view.
_ = try doc.key(.enter, .{});
try doc.typeChar('a');
view.pointer(&doc, &ui, .{ .x = x, .y = y, .down = down, .pressed = pressed, .mods = .{} });
doc.refresh();
view.draw(&doc, &ui, true);
// ...and once the frame is laid out:
view.measure(&doc, &ui, 1);
```

The text is kept as the file has it: its tabs stay tabs, drawn to the next stop, and `written` gives the text back with the file's own line breaks, `\r\n` or `\n`. `modified` says whether it changed since `markSaved`.

## Keys

| Keys | What they do |
| --- | --- |
| Arrows, Home, End, Page Up, Page Down, with Shift and Ctrl | Move, select, by words, to the ends |
| Enter, Tab, Shift+Tab | A new line indented as the language says; indent or unindent the lines picked |
| Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z | Undo, redo |
| Ctrl+/ | Comment the lines picked, or uncomment them |
| Ctrl+Space | Completions |
| F12, Ctrl+click | Go to the declaration |
| Ctrl+F, Ctrl+H, Ctrl+G | Find, replace, go to a line |
| F3, Shift+F3 | The next place, the one before |
| Escape | Close the lists over the code, then the find bar |

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
