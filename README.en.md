# Madi (마디)

[한국어](README.md)

A native macOS Markdown editor. **You edit the screen you are reading** — there is no
separate source pane and preview pane; the rendered document is the thing you edit.

![One Madi window. Only the second line, where the caret is, shows its ** and backtick markers, dimmed; every other line is drawn as a document — a heading, a checklist, italic and strikethrough, a quote, a table with aligned columns, and a syntax-highlighted Swift code block](docs/images/live-preview.png)

Only the line with the caret (the second line above) shows markers such as `**` and `` ` ``,
dimmed; every other line is drawn like a document. Press `⌘E` and the same document appears as
[plain source](docs/images/source-view.png) — that source is what gets saved, byte for byte.
The pictures are drawn by the real editor with `make screenshots` (2026-10-30).

**Madi** (마디) is a native Korean word for a joint or a segment — the same word as in
"say a word" (한 마디 하다). A Markdown document is a row of such segments — headings,
paragraphs, tables, code blocks — and this app works on them. `Madi` is the romanized form and
the bundle and executable name; it is one name written in two scripts, not two names.

```sh
make build    # xcodegen → xcodebuild
make test     # tests (no app launch)
make run      # build, then launch
```

AppKit · Swift 6 · **no dependencies**. No package manager, no web view, no second buffer.
The only things bundled are two fonts (Pretendard for text, IBM Plex Mono for code — both
SIL OFL 1.1).
How to build, test and contribute: [docs/building.md](docs/building.md) (Korean).

> **Status: 0.1.0, not distributed yet.** The app is ad-hoc signed
> (`CODE_SIGN_IDENTITY=-`), so it runs only on the Mac that built it. Running it on another Mac
> needs Developer ID signing and notarization.

> **The interface is in English and Korean.** Madi follows the system language; you can also
> pick one in Settings ▸ General ▸ Language (it applies the next time you open Madi). The
> documents under `docs/` are Korean only.

## Why another one

Most Markdown editors are one of two things: they show the raw source (source editing), or
they edit a rendered document inside a web view (WYSIWYG). Madi gets the second feeling with
**a single text system**.

`NSTextStorage` holds nothing but the Markdown source, and two layers sit on top of it.

1. **Styling** — headings get large type, `**bold**` becomes real bold, code gets a monospace
   font and a background, links get a blue underline.
2. **Marker hiding** — `#`, `**`, backticks, a link's `(URL)` and code fences take **zero width
   when the caret is not on their line.** The characters stay in the document and only vanish
   from the screen. Move the caret onto the line and they come back, so you can edit the
   structure.

So what gets saved is always exactly the Markdown you wrote. Nothing is re-serialized from a
document model, which means **opening and saving a file never changes it.**

## Features

The full list and every shortcut are in [docs/features.md](docs/features.md) (Korean). In short:

| | |
|---|---|
| Editing | Live preview ↔ Markdown source toggle (`⌘E`), syntax highlighting for 11 languages, table column alignment, inline images |
| Find | In-document search (`⌘F`), match count and stepping (`⌘G`) |
| Navigation | Outline · recent documents · file browser sidebar (each toggles) |
| Documents | YAML front matter card; `NSDocument` open, save, autosave and version restore |
| Export | PDF, a single Markdown file with images embedded as `data:` URLs, print |
| Tools | Apple Translation (between Korean and more than 20 languages, markup preserved, source and translation side by side), activity log (`⌘⇧L`), settings (`⌘,`) |
| Experimental | Block editor (`⌥⌘B`) — a second window that edits the document as an array of blocks. It is stage 1 of the design for grid tables; the default editor is unchanged |

## Requirements

- macOS 14 or later (`deploymentTarget`)
- To build: Xcode 26 or later and [xcodegen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`)
- **Apple Translation needs macOS 26 or later** (the `Translation` framework). Below that the
  menu items are disabled and everything else works. Translation needs the language packs
  installed in the system; when one is missing, Madi tells you where to get it.

## What does not work yet

Stated plainly. The background and plans are in [TODO.md](TODO.md) (Korean).

- **Tables are not drawn as grids.** They stay as text with aligned columns. That is not a
  missing piece of work but a consequence of the text system's model; what has to change is
  written up in the [block editor design](docs/block-editor-design.md).
- **No Mermaid diagrams and no KaTeX math.** The native route is expensive, and whether to use
  a hidden web view is waiting on a decision.
- **The interface comes in English and Korean only.** On a system whose language list has
  neither, Madi opens in Korean; choose English in Settings ▸ General ▸ Language.
- **Images in the middle of a line stay as source.** Only an image that has a line to itself
  is shown.
- **Remote images are not fetched by default.** Opening a document should not send requests
  out, and an address in a document can be a tracker. You can turn it on in Settings ▸
  General, and even then only `https` is fetched.
- **The front matter card is read-only.** Re-serializing YAML would quietly rewrite constructs
  the parser does not model (anchors, nested mappings, comments). The original block is kept
  byte for byte.
- **Typing in very large documents is a little heavy.** A 220,000-character document (about
  6,000 lines) opens in 0.5 s, app launch included, but near the top of it one keystroke takes
  about 35 ms. Lines are re-classified only from the edit onward; what remains is restyling the
  edited line and TextKit rebuilding that line's glyphs and its fallback font for Hangul.

## Layout

```
project.yml           xcodegen spec (the .xcodeproj is generated)
Sources/Madi/
  Core/               pure logic — Foundation only, no AppKit
  Editor/             the live-preview editor
  Panels/             sidebar · cards · sheets
  Services/           Apple Translation, decompression
  App/                NSDocument · windows · menus
Tests/MadiTests/      tests (no app launch)
docs/                 design documents
web-prototype/        the early web prototype (for reference)
```

That `Core` never uses AppKit is an enforced invariant — `make core-only` type-checks those files
on their own and fails if it breaks. More in [docs/architecture.md](docs/architecture.md) (Korean).

## Relation to other apps

Madi's layout and shortcuts follow the commercial Markdown editor **Mark.app** — the order of
the toolbar buttons, shortcuts such as `⌘⇧F`/`⌘⇧R`/`⌘⇧O`/`⌘E`, and the way search "paints every
match". Using that app and wishing it were native is where this repository started.

**No code was taken.** Madi is written from scratch in AppKit, and Mark.app is a Rust + web view
app, so there is no code to share in the first place. Its visible behavior was observed and the
same rules were implemented; where Madi deliberately differs, [docs/features.md](docs/features.md)
says so and why.

## License

[MIT](LICENSE).
