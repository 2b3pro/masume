# Changelog

All notable changes to Masume. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses semantic versioning while pre-1.0: a minor bump for new tools, formats,
or surfaces, a patch bump for fixes. Each release is tagged `vX.Y.Z` on `main`.

## [Unreleased]

### Added

- Zones: the Select tool drags a marching-ants region on empty canvas, rectangle or ellipse,
  as a pointer for the agent. It is not an annotation and never exports. Agents read it from
  the document summary (rect, shape, covering grid range), use `zone` as an address anywhere,
  and can mark one out for the person with `set_zone` (`masume zone`, `masume_set_zone`).
- On-device text recognition through `read_text`, `masume read-text`, and
  `masume_read_text`. It reads the untouched whole image, a grid range, or `zone` with
  Vision and returns text, confidence, full-image pixel and normalized bounds, and covering
  grid ranges without returning image data. Calls may provide recognition languages and
  custom words.
- A Command Line settings pane installs or updates the bundled `masume` executable.

### Changed

- Grid axis labels are navy-on-gray chips spaced 10 points outside the canvas; fit mode
  reserves the room, and zoomed in past an edge the chips ride along the inside of the window.
- The Crop tool also resizes the canvas: handles on the canvas's corners and sides (and a
  frame dragged past an edge) grow it with white on Apply Resize. The action bar shows the
  frame's width and height as editable fields.
- The app stays running when its last main window closes, while auxiliary windows retain
  their normal close behavior.
- App assembly prefers an available Apple Development or Developer ID identity and signs
  the bundled CLI with its Automation entitlement, falling back to ad-hoc signing with a
  warning when no identity is available.

### Fixed

- Apple Event failures, including Automation denial (`-1743`), now produce actionable CLI
  diagnostics instead of being flattened into a generic not-running error.
- Clicking or dragging the action bar's share control no longer crashes when AppKit asks its
  file-promise delegate for an operation queue from a background file-coordination thread.

## [0.4.0] - 2026-09-02

Counted and emoji stamps, an agent guide over MCP, and real CLI help.

### Added

- Numbered and lettered stamps: `#` flags count 1, 2, 3 and `A` flags A, B, C, each new one
  taking the count past the highest of its kind. With one selected, `+` and `-` change the
  count and `Tab` (or the stamp row) switches between digits and letters. Through the command service,
  stamps of kind `number` or `letter` accept and report `ordinal` and report `label`.
- Emoji stamps: the stamp row's last glyph shows any character you type, paste, or pick
  from Emoji & Symbols; the choice is remembered and edits a selected emoji stamp. Through
  the command service, stamps of kind `emoji` accept and report `emoji`.
- Shift while dragging a stamp's tail snaps it to 45° steps.
- An agent guide: the MCP handshake carries short server instructions and the `masume_guide`
  tool returns the full guide (session shape, grid grammar, element fields, error codes,
  token-saving habits). README gains directions for setting up MCP and working with an agent.
- `masume help <subcommand>` and `<subcommand> --help`: what each subcommand takes, with the
  keys every element type accepts and the grid address grammar. Help exits 0 on stdout.

### Fixed

- The `masume` CLI addresses the running app by process id. Addressing it by bundle
  identifier could hand the Apple Event to a stale Launch Services registration, where it
  timed out (-1712) while the app sat idle.

## [0.3.0] - 2026-09-02

The release where a person and an agent share the document: an editable project format, a
grid as the common spatial language, and three ways in for automation.

### Added

- **Projects.** `.masume` packages hold the original image, the annotations, and an
  attributed history of every committed change. Save, Save As with a new identity, Open,
  double-click to reopen. A recovery package shadows every commit, so a crash reopens what
  you had. The first save of a document with the unredacted original says so;
  Create Share-Safe Copy… writes only flattened pixels.
- **Grid.** A spreadsheet grid over the image, density tiered from the image's pixel size
  and stored in the project. `D5` is a cell, `D5:F14` a range, and `D5.3` a quadrant
  (1 to 4 clockwise from the upper left; quadrants nest, as in `D5.3.1`, four levels deep).
  Show Grid (`Cmd+G`), a toggle button beside the zoom control, and View ▸ Grid Density.
- **Command service.** Sixteen JSON commands with one envelope and error codes
  (`conflict`, `not_found`, `invalid_address`, `invalid_argument`, `unsupported`, `io`).
  Mutations carry the document id and expected revision and fail closed on a mismatch;
  agent edits land in the shared history and undo stack with the actor and reason.
- **AppleScript and JXA.** Read-only document properties and one `execute` verb
  (`Resources/Masume.sdef`).
- **`masume` command line.** Live subcommands over Apple Events, offline `info`, `export`,
  `resolve`, and `new` through the model and renderer libraries, exit codes that mirror the
  error codes. Bundled at `Contents/Helpers/masume`; `scripts/install-cli.sh` links it.
- **MCP server** (`mcp/`), stdio and Streamable HTTP with a bearer token, one `masume_*`
  tool per command, spawning the CLI. The app bundles it and a menu bar item starts and
  stops it, shows the port and tool count, and copies the URL or a JSON config;
  Settings ▸ MCP holds port, token, Node path, agent name, and start-at-launch.
- **Image layers.** Pasting or dropping an image onto an open document adds a layer with a
  rectangle, rounded, or circle mask, an optional border and shadow, and aspect-locked
  resizing. Hold `Option` while dropping to open a new tab instead. Replace Image from
  Clipboard moved to the File menu.
- **Option-drag** an annotation to drag off a copy and leave the original in place.
- **Tabs.** Untitled until named, press-and-hold to rename in place (renaming the package
  on disk for a saved project), an unsaved dot, and Close All Tabs (`Opt+Cmd+W` or
  `Opt`-click a close button) that visits each tab and asks about unsaved changes.
- Round-trip scripts against the built app: `scripts/ae-roundtrip.sh` (JXA) and
  `scripts/roundtrip.sh` (CLI, including kill and recover).
- App icon.

### Changed

- The close dialog offers Save, Don't Save, and Cancel; a tab holding only an imported
  image closes without asking.
- Opening a file from Finder opens a new tab rather than replacing the active one.
- The MCP server's default port is 8722 (8765 belongs to DEVONthink's).

### Fixed

- Unit tests no longer write recovery packages into the real Application Support folder.
- Callout text was clipped on boxes that had not yet been measured.
- Updating one end of an arrow or line through the command service no longer requires
  the other.

## [0.2.0] - 2026-09-02

### Added

- Callouts: speech bubbles and thought clouds with a tail, palette fill, white-or-black ink,
  and left, center, or right text alignment.
- One-shot tools hand back to Select after placing; clicking the active tool again locks it
  (a "+" badge). The pen is always sticky.
- Magnifier loupe, round or square, with a zoom slider under the selection.
- PDF import at 2× with a page picker for multi-page files.
- The stroke-width slider shows a font-size glyph while editing text.
- `VERSION` file and `vX.Y.Z` tags; the build script stamps the bundle.

## [0.1.0] - 2026-08-13

The Skitch-look fork as inherited from [2b3pro/kakico](https://github.com/2b3pro/kakico):
drop shadows, text styles, stamps, pen and highlighter, and remembered tool state.

[Unreleased]: https://github.com/2b3pro/masume/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/2b3pro/masume/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/2b3pro/masume/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/2b3pro/masume/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/2b3pro/masume/releases/tag/v0.1.0
