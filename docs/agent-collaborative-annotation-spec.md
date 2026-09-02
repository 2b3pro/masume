# Masume Agent Collaboration v1

**Status:** Draft  
**Date:** 2026-09-02  
**Scope:** Extend the existing native macOS annotation app; do not rebuild Masume inside LiveDoc.

## 1. Product definition

Masume v1 is a native, single-image, non-destructive annotation workspace shared by one human and one agent. The human can work directly in the existing Skitch-like interface. The agent operates on the same document through MCP. Both use a visible spreadsheet-style grid as a compact, deterministic spatial language.

The editable Masume project is the source of truth. PNG, JPEG, WebP, and single-page PDF are flattened exports.

## 2. Existing foundation

The current architecture already provides most of the required base:

- `AnnotationModel.Document` is `Codable` and stores a base-image reference, image-space canvas size, ordered annotations, and crop.
- Every annotation has a stable UUID and editable image-space geometry.
- Arrow, line, rectangle, ellipse, text, pixelate, and crop behavior already exist.
- `CanvasController` owns document state and snapshot-based undo/redo.
- `AnnotationRender.Renderer` creates flattened output independently of the UI.
- Images can be opened, pasted, or dropped, and exported as PNG, JPEG, or WebP.

The implementation should extend these seams rather than introduce a second canvas or annotation model.

## 3. Version-one boundaries

### Included

- One human and one agent working on the active document.
- One base image per document.
- Input from file open, drag-and-drop, or clipboard. Existing macOS screenshot workflows feed the clipboard or a file.
- Editable annotations until export.
- Shared chronological undo/redo and visible action history with actor attribution.
- Immediate autosave after each committed action; drag previews remain transient until pointer-up.
- Crash recovery restoring the last committed canvas state.
- Grid addressing, MCP inspection/mutation, and on-demand base-image viewing.
- Current-session memory for the last-used tool, color, width, fill, font, and shadow setting.
- Flattened PNG, JPEG, WebP, and single-page PDF export.

### Excluded

- Multi-page documents or PDF import.
- Multiple humans or multiple agents.
- Generative image editing, inpainting, or replacement patches.
- Automatic image analysis on load.
- Persistent style libraries or named presets.
- Live cursor broadcasting or speculative LiveDoc integration.

## 4. Coordinate and grid model

The canonical coordinate space remains image pixels with a top-left origin. Grid addresses are a presentation and command layer over that space, never window coordinates.

### Grid definition

- Columns use spreadsheet letters: `A` through `Z`, then `AA`, `AB`, and so on.
- Rows use one-based numbers: `1`, `2`, `3`, and so on.
- The grid covers the exact base-image bounds and scales with the image under zoom and pan.
- Grid display is toggleable. Address resolution works whether or not the grid is visible.
- Default density is chosen from the base-image pixel dimensions alone, never from the window or display, so the same image always receives the same default grid. See Grid sizing below.
- The chosen row and column counts are stored in the project so addresses never drift after reopening, and never drift if the default tiers change in a later release.
- Users may change grid density explicitly from the same preset list. Changing density is a document action, increments the stored grid version, and invalidates prior semantic-map results.

### Grid sizing

Cells are near-square and cover the image exactly. There is never a partial row or column, because a ragged last cell would break exact coverage and make the last address ambiguous. Each cell measures `W / cols` by `H / rows` image pixels, so a cell deviates from square by at most half a cell across the whole image; with twelve columns the width error is under five percent.

Density is tiered on the long side of the image in pixels. Tiers, not a viewport-derived cell size, because a viewport-derived grid is nondeterministic: the same screenshot imported into two window sizes would receive two different address spaces, headless callers and tests would need an invented viewport, and neither participant could predict the grid from the image alone. Tiers also keep the number of distinct grids small, which the agent can learn.

| Long side (px) | Cells across the long side |
| --- | --- |
| up to 800 | 8 |
| 801 to 1600 | 12 |
| 1601 to 2600 | 16 |
| 2601 to 4000 | 24 |
| over 4000 | 32 |

Derivation, also used when the user picks a preset manually:

```text
n      = tier(max(W, H))            // or the chosen preset: 8, 12, 16, 24, 32
target = max(W, H) / n              // desired cell size in image pixels
cols   = clamp(round(W / target), 2, 64)
rows   = clamp(round(H / target), 2, 64)
```

`round` is round-half-away-from-zero (Swift's `rounded()`), because exact halves occur at common sizes. The 900 row of a 1440 by 900 image gives 7.5 and must resolve to 8 on every platform.

Examples: a 1440 by 900 window capture gets 12 by 8; its 2x Retina capture at 2880 by 1800 gets 24 by 15; a 1170 by 2532 portrait phone capture gets 7 by 16; a 3840 by 2160 frame gets 24 by 14.

Resolution computes edges by multiplying integers before dividing, so edges are exact rationals and no float cell width accumulates drift:

```text
edgeX(c)     = c * W / cols         // c in 0...cols
edgeY(r)     = r * H / rows         // r in 0...rows
cell(c, r)   = rect(edgeX(c), edgeY(r), edgeX(c+1), edgeY(r+1))
center       = midpoint of cell(c, r)
range(a, b)  = rect(cell(a).minX, cell(a).minY, cell(b).maxX, cell(b).maxY)
pointToCell  = (min(cols-1, floor(x * cols / W)), min(rows-1, floor(y * rows / H)))
normalized   = divide by W and H
```

Column letters are bijective base 26. Parsing accumulates `n = n * 26 + (letter - 'A' + 1)` and the zero-based index is `n - 1`. Formatting repeats `n -= 1; emit 'A' + n mod 26; n /= 26` and reverses the output, so `Z` is 26, `AA` is 27, and `AZ` is 52. Validation rejects a column at or beyond `cols`, a row at or beyond `rows`, and a range whose second cell is left of or above the first.

Rendering draws lines in image space at the edge formulas and passes them through the existing zoom and pan transform. When zoomed out, labels thin to every k-th label where `k = ceil(24 / cellScreenPoints)`, and lines hide entirely below roughly six screen points per cell.

Known limit: a 4K capture at tier 24 has cells about 160 pixels wide, which is coarse for pointing at a small control. Exact normalized coordinates cover fine placement and the density presets cover the rest. If this bites in practice, sub-cell quadrant addressing such as `D5.3` fits the same resolver without changing stored counts.

### Address semantics

- A single cell such as `D5` resolves to the cell center when a point is required.
- A cell range such as `D5:F14` resolves to the rectangle from `D5`'s upper-left edge through `F14`'s lower-right edge, inclusive.
- APIs also return the four corners and normalized coordinates for any cell or range.
- Commands may use exact normalized coordinates for finer placement, but grid notation is the primary human-facing language.
- Parsing is case-insensitive and rejects nonexistent or reversed ranges with a clear error; it never silently clamps an invalid address.

Examples:

- `create arrow from B3 to D6` uses the centers of `B3` and `D6`.
- `create rectangle over D5:F14` uses the full inclusive bounding region.
- `inspect D5:F14` crops that region from the untouched base image.

## 5. Base-image observation

Observation and annotation state must remain separate.

- Image inspection is manually invoked by the user or explicitly requested by the agent; it does not run automatically when an image loads.
- Inspection always reads the untouched base image, never the composited annotation layer.
- A region request resolves the grid range to pixel bounds and creates an in-memory crop. A small configurable context margin may be included for vision-model comprehension.
- Crops are background machinery and are not added to the project or history.
- The MCP response identifies the document ID, document revision, requested grid range, exact source pixel bounds, and whether a context margin was added.
- Any semantic map produced by a model is ephemeral and keyed to the base-image checksum plus grid-definition version. It becomes stale when either changes.

## 6. MCP contract

The MCP server is an adapter over the same application services used by the UI. It must not synthesize mouse events or maintain a second copy of document state.

### Transport

Masume is a running GUI application, while the agent host launches MCP servers as stdio child processes, so a bridge between the two is required. Version one uses Apple Events.

- Masume ships a scripting definition (`Masume.sdef`) and sets `NSAppleScriptEnabled` and `OSAScriptingDefinition` in `Info.plist`. Apple Events are handled by the existing `AppDelegate`.
- The MCP server is a separate TypeScript process. It forwards each tool call to the app with `osascript -l JavaScript`, holds no document state, and implements no document logic. AppleScript and JXA clients share the same surface; JXA is only the client language the MCP server happens to use.
- The scripting surface is thin. Each document exposes read-only properties: `id`, `revision`, `name`, canvas width and height, grid columns, rows, and version, and `dirty`. The application exposes `active document`. All operations go through one verb, `execute`, which takes a JSON command string and returns a JSON envelope of the form `{ "ok": true, "result": ... }` or `{ "ok": false, "error": { "code": ..., "message": ... } }`. Error codes are `conflict`, `not_found`, `invalid_address`, `invalid_argument`, `unsupported`, and `io`. Malformed JSON is the only condition reported as an Apple Event error.
- Every MCP tool maps one-to-one onto a command name handled by the command service extracted in Phase 3. The UI, the `execute` verb, and any future transport call that same service; no transport may implement a command on its own.
- Binary results do not travel inside Apple Events. `masume_view_base_image` writes the crop as a PNG to a temporary file under the app's caches directory and returns the path plus the metadata in section 5. The MCP server reads the file, embeds it as image content, and deletes it. Crops are never written inside the project package.
- A full scriptable object model (native `annotation` classes, `whose` filters, per-property verbs) is deferred. It can be added later over the same service if Shortcuts or Script Editor users need it.

Why Apple Events rather than an in-app HTTP endpoint or a socket:

- The MCP protocol stays in the maintained TypeScript SDK. The Swift side implements no MCP and tracks no protocol churn, and no third-party Swift package is needed.
- Apple Events are delivered serialized on the main run loop, so agent mutations interleave with human edits without a locking design. The revision assertion below runs inside the handler.
- macOS Automation permission gates which processes may drive the app. A localhost port has no such gate, is reachable by any local process and by web pages through DNS rebinding, and would need its own authentication.
- No listening port and no server entitlement if the app is ever sandboxed.

Operational notes:

- Automation grants are keyed to the calling binary path. Version-pathed runtimes such as `bun` or `node` lose the grant on every upgrade. The MCP server should invoke `osascript` through a stably signed helper bundle, or document that the grant must be renewed after runtime upgrades.
- Each call spawns `osascript`, budget roughly 100 to 300 ms per call. Batch commands exist partly for this reason.
- A Unix-domain socket transport over the same command service is the designated future seam if latency or crop payloads become a problem. It must not introduce a second service.

### Revision assertions

Every mutation requires `documentId` and `expectedRevision`. The operation fails closed on mismatch rather than writing into the wrong or stale document. Successful mutations return the new revision and affected element IDs.

### Read tools

- `masume_get_active_document` returns identity, revision, canvas size, grid definition, selection, dirty state, and summary counts.
- `masume_list_elements` returns ordered annotation objects and their stable IDs.
- `masume_get_element` returns one complete editable object.
- `masume_resolve_grid` converts a cell or range to image-pixel and normalized geometry.
- `masume_view_base_image` returns the untouched full image or a grid-addressed crop suitable for model vision.
- `masume_get_history` returns committed actions with actor, timestamp, operation, and affected IDs.

### Mutation tools

- `masume_create_element` creates arrow, line, rectangle, rounded rectangle, ellipse, text, highlight, numbered callout, pixelate, or freehand annotations.
- `masume_update_element` changes geometry, text, color, fill, width, font, shadow, corner radius, pixelation strength, or z-order.
- `masume_delete_elements` deletes explicit IDs.
- `masume_set_crop` sets, updates, or clears the non-destructive crop.
- `masume_undo` and `masume_redo` move through the single shared history.
- `masume_save_project` saves the editable source document.
- `masume_export` writes a flattened PNG, JPEG, WebP, or single-page PDF.

Each mutating call carries `actorId` and a short human-readable `reason` for the history panel. Batch creation or updates must commit atomically as one undoable action.

### Safety and validation

- File-writing tools require explicit absolute destinations or an interactive save panel; no implicit workspace-relative writes.
- Mutations validate finite coordinates, supported styles, image bounds where required, and target element existence before committing.
- Inspection tools never include annotations unless a future, separately named composited-view tool is added.
- Export never changes the editable document.

## 7. Editable project format

Restore `.masume` as a versioned package, not the prior bare JSON payload.

Suggested package contents:

```text
Example.masume/
  manifest.json
  base-image.<original-or-lossless-extension>
  preview.png
  history.jsonl
```

`manifest.json` contains a format version, document UUID, revision, canvas size, grid definition, ordered annotation objects, crop, creation/update timestamps, and the base-image checksum. The package embeds a lossless source image so reopening never depends on an external path. Unknown future annotation fields should be preserved where feasible, and unsupported newer format versions must fail clearly rather than partially load.

Saving uses atomic package replacement. Normal Save overwrites the bound project; Save As creates a new document identity. Opening verifies the manifest, image checksum, dimensions, and element IDs before replacing the active canvas.

### Redaction disclosure

An editable project necessarily contains the original, unredacted base image. Upstream Kakico previously removed native project saving because a shared `.kakico` file could expose content hidden by pixelation.

The new design must make this boundary unmistakable:

- The first project save explains that `.masume` contains the unredacted original and is not safe to share as a redacted deliverable.
- Export copy uses explicit language such as **Export Flattened Image**.
- Finder metadata and Quick Look identify the item as an editable Masume project, not a finished image.
- A **Create Share-Safe Copy** command exports a flattened artifact containing no editable source image.
- The project package must not claim that encryption solves recipient disclosure; anyone able to open the project can access the base image.

## 8. History, autosave, and recovery

- One chronological operation history includes both human and agent commits.
- History entries contain operation ID, actor, timestamp, before/after revision, affected IDs, and a reversible delta or snapshot reference.
- Undo reverses the latest committed shared action regardless of actor. Redo restores it.
- The history UI names the actor and operation, for example, `Nova added arrow 4F2A` or `Ian changed rectangle color`.
- Autosave runs after each committed action and after metadata changes. In-progress pointer movement or inline typing is committed once the interaction ends.
- Autosave failures are visible and leave the document dirty; the app must not report success from an in-memory update alone.
- Recovery data is separate from an explicitly saved project and may be pruned after a clean close.
- A newly imported image receives recovery autosave immediately even before the user chooses a project path.

The existing snapshot undo implementation may remain for v1, but persistence should serialize durable operation metadata rather than exposing private controller snapshots as the file format.

## 9. Annotation additions

Preserve all existing tools and add only the agreed v1 gaps:

- Rounded rectangle as a rectangle style with editable corner radius.
- Translucent rectangular highlight.
- Freehand stroke stored as a simplified image-space point path.
- Numbered callout marker with editable integer and automatic next-number default.
- Optional shadow for arrows, lines, shapes, text, and callouts.
- Shadow is a global current-session default with a per-object override.

Current-session style memory resets when the application quits. It applies to newly created objects and does not retroactively alter existing annotations.

## 10. UI changes

- Add a toolbar grid toggle and a compact grid-density control offering the five presets from section 4, with the tier default marked.
- Draw column labels across the top and row labels down the left, inside the image overlay but outside exports.
- Add a history panel showing shared actions and actor attribution.
- Add Save, Save As, Export Flattened Image, and Create Share-Safe Copy commands with conventional shortcuts.
- Add agent connection status without exposing crop transport or model internals.
- Keep selection handles and annotations visually above the grid; the grid must not intercept pointer events.
- Never include the grid in flattened export unless a future explicit **Export With Grid** option is added.

## 11. Delivery sequence

### Phase 1: Durable document

1. Introduce a versioned project-package codec and validation.
2. Add dirty tracking, Save/Save As/Open, atomic writes, and recovery autosave.
3. Restore projects across launch and add the redaction disclosure and share-safe export path.

### Phase 2: Shared spatial language

1. Add the stored grid definition and pure address parser/resolver in `AnnotationModel`.
2. Render the non-exporting grid overlay and labels in the existing canvas.
3. Add grid controls and tests across zoom, pan, portrait, landscape, and non-divisible image sizes.

### Phase 3: Agent surface

1. Extract document commands from `CanvasController` into a reusable command service with JSON-codable commands and results.
2. Add the scripting definition, the read-only document properties, and the `execute` verb over that service, with document/revision assertions inside the handler.
3. Add the TypeScript MCP server that forwards tool calls over Apple Events. Implement read tools first, then mutations, batch commits, history, save, and export.
4. Prove a round trip: agent reads revision, resolves cells, adds an arrow, human moves it, agent reads the updated object, either participant undoes it, and the state survives restart.

### Phase 4: Remaining annotation vocabulary

Add rounded rectangles, highlights, freehand strokes, numbered callouts, shadows, and session style memory after the grid/MCP round trip is reliable.

### Phase 5: On-device intelligence (optional)

Vision text mapping first, since it needs no target change. The Foundation Models command bar and App Intents follow once the macOS 26 deployment-target decision is made. Details in section 15.

## 12. Acceptance criteria

Version one is complete when all of the following are demonstrably true:

1. A user can create a document from clipboard, file open, or drag-and-drop and save it as `.masume`.
2. Reopening restores the exact base image, crop, z-order, editable annotations, styles, grid, and current revision.
3. Masume warns that the editable project contains the original image and produces a flattened share-safe export.
4. `D5` resolves to its cell center and `D5:F14` resolves to the inclusive outer rectangle, independent of window size and zoom.
4a. The default grid for a given image is identical regardless of window size, display, or whether the import was headless.
5. The agent can view only the untouched base image, either whole or by grid range, without annotations leaking into the crop.
6. An MCP mutation with the wrong document ID or stale revision makes no change and returns an actionable conflict.
7. Human and agent edits appear in one attributed history and participate in shared undo/redo.
8. Every committed edit autosaves; killing and reopening the app restores the last confirmed commit.
9. Export produces a flattened artifact without grid lines, edit metadata, history, or recoverable base pixels outside the exported result.
10. The complete agent-human round trip passes both automated tests and a manual UI smoke test.

## 13. Required tests

- Grid parsing and resolution, including `Z` to `AA`, invalid addresses, ranges, aspect ratios, and fractional cell edges.
- Tier selection and count derivation for representative sizes: a 200 by 200 icon, 1440 by 900, 2880 by 1800, 1170 by 2532 portrait, 3840 by 2160, and each tier boundary; stored counts survive a change to the tier table.
- Apple Event round trip: `osascript` reads document properties and calls `execute` for a create, a conflict, and a base-image crop, checking the JSON envelope and error codes. This is an integration test against the built app and may be excluded from the unit suite.
- Project round-trip, schema migration, corruption, checksum mismatch, duplicate IDs, atomic-save failure, and newer-version rejection.
- Redaction safety: flattened exports contain only rendered pixels; editable projects trigger disclosure and retain the original by design.
- Revision conflicts and wrong-document mutation refusal.
- Batch atomicity and shared undo/redo across alternating human/agent actions.
- Base-image crop dimensions, requested bounds, context margins, and proof that annotations are excluded.
- Crash recovery after each supported committed action.
- Rendering for new annotation types and shadow on/off at representative scales.

## 14. Deliberate future seams

The project model may later add multi-party collaboration or generated image-patch layers, but v1 should implement neither. Future patches can conform to the existing ordered-element model without changing the principle that the base image remains immutable and export is the only flattening boundary.

## 15. Apple Intelligence and on-device frameworks

None of this is on the v1 critical path. Each item is an additional client of the command service from Phase 3, and none of them changes the rules already set: observation stays separate from annotation, nothing analyzes an image on load, and the base image never leaves the machine through these paths.

### Vision framework: on-demand text map

Available on macOS 15, so it needs no deployment-target change.

- Add `masume_read_text`, taking an optional grid range. It runs `RecognizeTextRequest` on the untouched base image, or on the crop for the range, and returns each recognized string with pixel bounds, normalized bounds, the covering cell range, and confidence.
- Results are a semantic map in the sense of section 5: ephemeral, keyed to the base-image checksum plus grid version, and discarded when either changes.
- This lets the agent locate a labeled control by text and address it by cell without pulling a crop image through MCP.
- The same request backs an optional **Find Text** field in the UI that highlights the matching cells. It runs only when invoked.
- Rectangle and document-structure requests are deferred; text is the only v1 candidate.

### Foundation Models: natural-language command bar

Requires macOS 26 for the framework and Apple Intelligence enabled on the Mac. The current target is macOS 15, so this ships only after a deliberate target bump or behind `#available` guards, and the control is hidden when the model is unavailable.

- A command bar lets the human type `red arrow from B3 to D6` or `pixelate D5:F14`. The on-device model produces a `@Generable` command struct that mirrors the command service's JSON commands, so output is schema-valid by construction and routes through the same validation as MCP and Apple Event calls.
- Commands from the bar carry the human `actorId`, and the typed phrase becomes the history `reason`.
- The model is text-only and receives the grid definition, element summaries, and the phrase. It never receives pixels, and it is never used to describe or summarize the image.
- Parse failures show the text unchanged with the model's error; nothing is guessed or clamped.
- Inference is on-device only. Private Cloud Compute is not used for document content.

### App Intents: Shortcuts and Siri

- Define intents for a small subset of commands: create an element from grid addresses, toggle the grid, export a flattened image, and create a share-safe copy. Each intent calls the command service with `actorId` set to `shortcuts`.
- This gains Shortcuts, Siri, and Spotlight, and on macOS 26 the Apple Intelligence assistant surface.
- App Intents is not the agent transport. `shortcuts run` is slower than an Apple Event and returns strings, so the MCP server keeps using section 6.

### Writing Tools

Text annotation editing on macOS 26 gets Writing Tools from the system text view with no work required. Nothing in the document model changes.

### Delivery

Vision text mapping can follow Phase 4 immediately. The command bar and App Intents wait on the deployment-target decision and ship as Phase 5.

### Tests

- Text map: a synthetic image with strings at known pixel positions yields the correct cell ranges at two grid densities, and the map is invalidated when density changes.
- Command bar: a fixture set of phrases produces commands identical to hand-written JSON; an ambiguous phrase produces an error, not a guess.
- App Intents: each intent produces the same history entry as the equivalent MCP call, with the `shortcuts` actor.
