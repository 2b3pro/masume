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
  Delete. Stroke color, width, pixel size, opacity, text style, alignment, bubble shape, and
  stamp glyph are remembered
  across launches, with sizes scaled to each image so they look the same on any screenshot.
- **Navigation:** zoom in and out (`Cmd++` / `Cmd+-`), fit to window (`Cmd+0`), pinch to zoom,
  `Cmd`+scroll wheel to zoom about the pointer, and hold `Space` and drag to pan when zoomed
  in.
- **Output:** export as PNG, JPEG, or lossy WebP (`Cmd+E`); copy to clipboard (`Cmd+Shift+C`);
  drag out as a PNG file.
- **Tabs:** new tab (`Cmd+T`), close tab (`Cmd+W`), previous and next tab (`Opt+Cmd+←/→`).
  Edit multiple images in separate tabs without losing work.

## Install

Masume is not distributed as a binary; build it from source (below).

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
  including the Skitch shadow, text styles, stamp pins, and pen strokes.
- `Sources/Masume/` — the app: tabs, canvas, palette, export, and tool-state persistence.
- `Tests/` — unit tests for all three, including synthetic-event tests that drive the canvas
  view directly for gestures such as Shift-click lines, space-drag panning, and `Cmd`+scroll.

## License

Masume's own contributions (everything added on top of
[tk3fftk/kakico](https://github.com/tk3fftk/kakico)) are released under the
MIT License; see [LICENSE](LICENSE). The original Masume code is Copyright
Hiroki Takatsuka and has no license file at the time of writing, so it
remains all rights reserved until one is added upstream. Redistribution of
Masume builds should wait for that.
