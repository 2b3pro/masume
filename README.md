# Masume

Masume is a native **Apple Silicon (arm64)** annotation workspace for macOS, written in Swift
(SwiftUI shell + AppKit canvas, Core Graphics / Core Image rendering). One human and one agent
mark up the same image: the human through a Skitch-like interface, the agent through MCP, both
speaking a spreadsheet-style grid (`D5`, `D5:F14`) as a shared spatial language. The editable
project is the source of truth; PNG, JPEG, WebP, and PDF are flattened exports.

Masume grew out of [2b3pro/kakico](https://github.com/2b3pro/kakico), a Skitch-look fork of
[tk3fftk/kakico](https://github.com/tk3fftk/kakico). That fork continues separately as a plain
Skitch alternative in line with upstream. Masume is where the agent-collaboration work lives;
see [docs/agent-collaborative-annotation-spec.md](docs/agent-collaborative-annotation-spec.md).

## What it does

Open, paste, or drop an image or a PDF, mark it up, and export (shortcuts in parentheses).
A PDF page is rasterized at 2× on import; a multi-page PDF shows a page picker first.

- **Tools:** Select (`V`), Arrow (`A`), Line (`L`), Rectangle (`R`), Ellipse (`O`), Pen (`D`),
  Text (`T`), Callout (`B`), Stamp (`S`), Magnify (`M`), Pixelate (`P`), and Crop (`C`).
- **Skitch look:** arrows, lines, rectangles, and ellipses cast a soft drop shadow that scales
  with the stroke width and stays identical at every export size.
- **Text:** three styles, **Shadow** (white or black halo plus drop shadow), **Outline**, and
  **Plain**, chosen from the palette or by clicking the round "a" button above a selected text
  box, which previews the style you will get next. Side handles set the width and the text
  re-wraps; the bottom-right handle scales the font. Lines align left, center, or right from
  the alignment control.
- **Callouts:** a text box in a speech bubble or thought cloud with a tail. Press where the
  tail should point, drag to where the bubble should sit, release, and type. The bubble fills
  with the stroke color; its border and text use the white-or-black ink. Drag the tail tip to
  re-aim it; a tip inside the bubble hides the tail. Pick speech or thought from the row
  beside the Callout tool. A plain text box becomes a callout (and back) from the **Bubble**
  row in the alignment control.
- **Stamps:** check, cross, exclamation, question, and heart as Skitch-style pins. Click to
  place; drag while placing to aim the tail; drag the tail later to re-aim; drag the disk edge
  to resize. Pick the glyph from the row that appears beside the Stamp tool.
- **Magnifier:** a loupe that shows the image under it enlarged. Press where the loupe should
  center and drag outward to size it (a plain click gives a default size); corner handles
  reshape it afterwards, so a circle can become an oval. Drag the slider under a selected
  loupe to set the zoom (1.5× to 8×). Round or square from the row beside the Magnify tool;
  the ring uses the stroke color and width. Loupes magnify the image and any pixelation over
  it, never other annotations.
- **Pen and highlighter:** freehand strokes with round caps. Lower the opacity to turn the pen
  into a highlighter. Shift-click twice to draw a straight line between two points.
- **One-shot tools:** after you place an annotation the tool hands back to Select, so the
  next canvas click deselects instead of creating another. Click the active tool (or press
  its key) again to lock it; a "+" badge appears and it keeps creating until you click it
  again. The pen is always sticky. Locks last for the session.
- **Editing:** select, move, and resize via handles; Undo (`Cmd+Z`), Redo (`Cmd+Shift+Z`),
  Delete. Stroke color, width, pixel size, opacity, text style, alignment, bubble shape, loupe
  shape and zoom, and stamp glyph are remembered across launches, with sizes scaled to each
  image so they look the same on any screenshot.
- **Navigation:** zoom in and out (`Cmd++` / `Cmd+-`), fit to window (`Cmd+0`), pinch to zoom,
  `Cmd`+scroll wheel to zoom about the pointer, and hold `Space` and drag to pan when zoomed
  in.
- **Grid:** a spreadsheet grid over the image, the shared spatial language for people and
  agents: `D5` is a cell, `D5:F14` a range. Toggle it with Show Grid (`Cmd+G`); it never
  exports. The default density comes from the image's pixel size alone, so the same image
  always gets the same addresses, and the counts are stored in the project so they never
  drift. Pick a different density from View ▸ Grid Density; that is a document action, so
  it is undoable and recorded.
- **Image layers:** pasting or dropping an image onto an open document adds it as a layer,
  centered and scaled to fit half the canvas, not a replacement. Hold `Option` while dropping
  to open the file in a new tab instead. Corner handles resize it
  with the aspect kept. The image-layer control masks it as a rectangle, rounded rectangle,
  or circle, and toggles a border (stroke color and width) and the drop shadow. The pixels
  are saved in the project's `assets` folder. To swap the base image instead, use
  File ▸ Replace Image from Clipboard.
- **Tabs and names:** a tab says Untitled until you name it. Press and hold the tab title to
  rename in place; for a saved project that renames the package on disk. A dot on the tab
  means unsaved changes.
- **Projects:** Save (`Cmd+S`) writes an editable `.masume` package: the original image as
  PNG, the annotations, and an attributed history of every committed change. Save As
  (`Cmd+Shift+S`) makes a copy with a new identity. Open (`Cmd+O`) or double-click a
  package to keep editing. Every committed action is also shadowed into a recovery package
  under Application Support, so after a crash the app reopens what you had, unsaved and
  marked with a dot in its tab.
- **Redaction and sharing:** a project keeps the unredacted original, and the first save of
  each document says so (with a "Don't show this again" option). To share a pixelated
  result use **Create Share-Safe Copy…**, which writes only the flattened pixels, or
  **Export Flattened Image…**.
- **Output:** export as PNG, JPEG, or lossy WebP (`Cmd+E`); copy to clipboard (`Cmd+Shift+C`);
  drag out as a PNG file.
- **Tabs:** new tab (`Cmd+T`), close tab (`Cmd+W`), previous and next tab (`Opt+Cmd+←/→`).
  Edit multiple images in separate tabs without losing work. Close All Tabs (`Opt+Cmd+W`, or
  `Opt`-click a tab's close button) brings each tab to the front in turn and asks about
  unsaved changes before closing it.

## Agents and automation

Masume has one command service inside the app and three ways in, all of which speak the same
JSON commands and get the same `{ok, result}` or `{ok, error: {code, message}}` envelope:

- **`masume` command line.** Live subcommands send one Apple Event each to the running app:
  `masume doc`, `masume resolve D5:F14`, `masume add arrow from=B3 to=D6 --reason "…"`,
  `masume view D5:F14 --out crop.png`, `masume undo`, `masume save ~/Shots/Login.masume`,
  `masume export out.png`, and `masume exec '<json>'` for anything by name. Mutations default
  to the active document at its current revision and say so on stderr; pass `--doc` and
  `--revision` to pin them. Offline subcommands need no app: `masume info file.masume`,
  `masume export file.masume out.png`, `masume resolve --file file.masume D5`, and
  `masume new shot.png file.masume [--page n]` for images and PDFs. Exit status mirrors the
  error code (2 conflict, 3 not found, 4 invalid address, 5 invalid argument, 6 unsupported,
  7 io, 10 Masume not running, 64 usage). Install with `bash scripts/install-cli.sh`.
- **AppleScript and JXA.** `Application("Masume").activeDocument.revision()` and
  `Application("Masume").execute(json)`; see `Resources/Masume.sdef`.
  `scripts/ae-roundtrip.sh` drives the built app this way.
- **MCP.** The server in `mcp/` spawns the CLI for each tool call; stdio by default, Streamable
  HTTP on request. See `mcp/README.md`.

Every mutation carries the document id and expected revision and fails closed on a mismatch,
and every agent edit lands in the same history and undo stack as yours, attributed and with
the reason the agent gave.

## Install

Masume is not distributed as a binary; build it from source (below).

## Versioning

The current version lives in [`VERSION`](VERSION) and follows semantic versioning while the
app is pre-1.0: a minor bump for new tools or formats, a patch bump for fixes. The build
script stamps it into the bundle, and each release is tagged `vX.Y.Z` on `main`.

| Version | Highlights |
|---|---|
| 0.2.0 | Callouts (speech and thought) with text alignment, one-shot tools with a lock, the magnifier loupe with a zoom slider, PDF import at 2× with a page picker. |
| 0.1.0 | The Skitch-look fork as inherited from kakico: shadows, text styles, stamps, pen and highlighter, remembered tool state. |

## Build & Run

```sh
swift test                       # Run unit tests (model, renderer, and app)
bash scripts/build-app.sh        # Build & assemble an ad-hoc-signed Masume.app
open build/Masume.app
```

Requirements: macOS 15+, Xcode/Swift toolchain. The build script produces a native arm64,
ad-hoc-signed bundle (no Apple Developer account required). The repository's lint hook uses
[SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`).

## Project layout

- `Sources/AnnotationModel/` — pure value-type model (no AppKit or SwiftUI).
- `Sources/AnnotationRender/` — Core Graphics rendering of a `Document` into a `CGImage`,
  including the Skitch shadow, text styles, callout bubbles, stamp pins, loupes, and pen
  strokes.
- `Sources/Masume/` — the app: tabs, canvas, palette, PDF import, export, and tool-state
  persistence.
- `Tests/` — unit tests for all three, including pixel checks on rendered output and
  synthetic-event tests that drive the canvas view directly for gestures such as the
  callout and loupe drags, Shift-click lines, space-drag panning, and `Cmd`+scroll.

## License

Masume's own contributions (everything added on top of
[tk3fftk/kakico](https://github.com/tk3fftk/kakico)) are released under the
MIT License; see [LICENSE](LICENSE). The original Kakico code is Copyright
Hiroki Takatsuka and has no license file at the time of writing, so it
remains all rights reserved until one is added upstream. Redistribution of
Masume builds should wait for that.
