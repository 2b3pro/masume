# Phase 1: Durable document, implementation plan

Companion to sections 7 and 8 of `agent-collaborative-annotation-spec.md`. The spec says what
the package holds and how saving behaves; this plan says how the code gets there, in four
commits that each leave the suite green.

Decisions made at kickoff (2026-09-02):

- The base image is stored as PNG in every package, re-encoded once at import.
- Recovery packages reopen automatically in tabs on relaunch, marked unsaved.
- The unredacted-original disclosure shows on the first save of each document, with a
  "Don't show again" checkbox that silences it globally.
- Each history entry carries metadata plus the full before and after objects of the
  elements it touched, so the file is reversible without exposing controller snapshots.

## Shape

```
Example.masume/
  manifest.json      formatVersion, id, revision, canvasSize, crop, elements,
                     createdAt, updatedAt, baseImage {fileName, sha256, width, height},
                     unknown top-level keys preserved on round trip
  base-image.png     written once, immutable
  preview.png        flattened at most 512 px on the long side, cosmetic, debounced
  history.jsonl      one HistoryEntry per line, append-only
```

Two kinds of package, same codec:

- **Recovery package** under `~/Library/Application Support/Masume/Recovery/<id>.masume`.
  Written after every committed action from the moment an image is imported. Records the
  bound project path when there is one. Pruned on a clean close.
- **Project package** wherever the user saved it. Written by Save and Save As only.

`revision` lives on the project session, not on `Document`: undo restores an older
`Document` but the revision keeps climbing, which is what an agent's `expectedRevision`
needs. `Document` itself does not change in this phase.

Dirty means `revision != lastSavedRevision`. Autosave to the recovery package never clears
it; only Save does.

## Commit 1: package codec (AnnotationModel, Foundation only)

`Sources/AnnotationModel/Project/`

- `ProjectManifest`: Codable with a custom decoder that keeps unknown top-level keys in an
  `extra: [String: JSONValue]` bag and re-emits them. `formatVersion` 1. Decoding a higher
  version throws `ProjectError.unsupportedVersion`.
- `Actor` (`id`, `name`) and `HistoryEntry` (`id`, `actor`, `timestamp`, `revisionBefore`,
  `revisionAfter`, `summary`, `affected`, `before`, `after`, `cropBefore`, `cropAfter`).
  `HistoryEntry.diff(from:to:actor:revision:)` computes affected ids and both object lists.
  `HistorySummary.sentence(for:actor:)` produces "Ian added arrow 4F2A" style text: verb from
  the diff (added, deleted, changed, moved), kind from the element, short id from the UUID.
- `ProjectPackage`: `create(at:manifest:baseImagePNG:preview:history:)` builds the package in
  a temporary sibling directory and moves it into place with `replaceItemAt`, so a half-written
  package never exists at the destination. `update(at:manifest:preview:appending:)` writes
  `manifest.json` through a temp file plus rename and appends history lines in place; the base
  image is never rewritten. `read(at:)` decodes the manifest, checks the version, verifies the
  base image's SHA-256 (CryptoKit) and pixel size against the manifest and the canvas size,
  and rejects duplicate element ids; returns manifest, base image bytes, and history.
- `ProjectError`: `unsupportedVersion`, `corruptManifest`, `missingBaseImage`,
  `checksumMismatch`, `sizeMismatch`, `duplicateElementIDs`, `io`.

Tests: round trip; unknown keys survive; every error case; atomic create leaves nothing
behind when the temp move fails; history append keeps earlier lines byte-identical.

## Commit 2: project session in the controller (Masume)

- `ProjectSession` state on `CanvasController`: `projectID`, `revision`,
  `lastSavedRevision`, `projectURL`, `history`, `baseImagePNG`, `actor`, `recoveryURL`.
  `isDirty` and `title` derive from it.
- One commit funnel. `commitInteraction`, `perform`, `undo`, `redo`, and `applyCrop` all
  call `didCommit(before:after:summary:)`, which bumps the revision, appends the history
  entry, and autosaves. Undo and redo record entries too ("Ian undid: added arrow 4F2A"), so
  the log and the revision are complete.
- Autosave: manifest and history written synchronously on the main actor after each commit
  (small JSON); the preview is rendered at reduced scale on a 1 s debounce. A write failure
  surfaces as a toast and leaves the document dirty. The recovery directory and the file
  system are injected so tests use a temporary directory.
- Import paths (`load(image:sourceURL:)`) create the session, encode the base PNG once, and
  write the first recovery package immediately, before any project path exists.

Tests: revision and history across perform, interaction, undo, redo, and crop; recovery
package exists after every commit and its manifest matches the document; a failing write
leaves dirty and shows the toast; importing writes recovery before any edit.

## Commit 3: Save, Save As, Open, recovery, and file type (Masume)

- File menu: Open… (`Cmd+O`, now accepts `.masume`), Save (`Cmd+S`), Save As… (`Cmd+Shift+S`),
  Export Flattened Image… (the renamed Export, `Cmd+E`).
- Save without a URL runs Save As. Save As writes a new package with a new document id, then
  binds the URL. Save writes to the bound URL and sets `lastSavedRevision`. Both go through
  `ProjectPackage.create` (the whole package is rewritten atomically on Save; the base image
  is unchanged, so the cost is the PNG copy).
- Open reads and verifies, then loads into the active tab if it is empty, else a new tab.
  Errors from `read` are shown by name.
- Finder: `UTExportedTypeDeclarations` for `com.2b3pro.masume.project` (extension `masume`,
  conforms to `com.apple.package`, description "Masume Project") and a matching
  `CFBundleDocumentTypes` entry, both in `Resources/Info.plist`. `application(_:open:)` routes
  double-clicked packages and images through the same open path.
- Tab title: project name or "Untitled", with a dirty marker; the window's
  `isDocumentEdited` follows the active tab.
- Close and quit: a dirty bound document offers Save / Don't Save / Cancel; an unbound one
  keeps today's discard confirmation. A clean close prunes the recovery package.
- Recovery on launch: `WorkspaceController` scans the recovery directory and reopens each
  package in a tab, restoring the bound project URL if the manifest recorded one, marked
  unsaved.

Tests: save binds and clears dirty; save-as changes identity; open rejects each error with
its message; a controller created over a recovery directory with two packages comes up with
two tabs; a clean close removes the recovery package and a dirty close keeps it.

## Commit 4: disclosure, share-safe copy, docs

- Disclosure sheet before the first save of each document: "This project contains the
  original, unredacted image. Anyone who can open it can see what pixelation hides. Share
  a flattened export instead." Buttons Save and Cancel; checkbox "Don't show this again".
  The per-document flag lives in the session; the global opt-out in UserDefaults.
- File menu: Create Share-Safe Copy… writes a flattened PNG (current export bounds) through a
  save panel defaulting to "<name> share-safe.png". It is `ExportService.export` with a
  fixed format and a name; no new rendering path.
- README: Save, Open, recovery, disclosure, share-safe copy. Spec: mark Phase 1 done.

Tests: disclosure shows once per document and not after opt-out (presenter injected); the
share-safe copy is a valid PNG with no package alongside it.

## Out of scope in this phase

Grid definition in the manifest (Phase 2 adds it as an optional key; the `extra` bag already
carries it if present), undo across restart from the history file, Quick Look thumbnails
(the preview is in the package for a future extension), and the command service.
