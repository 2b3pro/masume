# Phase 3: Agent surfaces, implementation plan

**Status:** shipped 2026-09-02 in five commits on `feat/agent-surfaces`, as laid out below.

Companion to section 6 of `agent-collaborative-annotation-spec.md`. One command service in the
app; MCP, the `masume` CLI, and AppleScript are thin clients of it. Five commits, each leaving
the suite green.

## Commit 1: the command service (Masume)

`Sources/Masume/Commands/`

- **Request.** One JSON object per call:
  `{"command": "...", "documentId"?, "expectedRevision"?, "actorId"?, "actorName"?, "reason"?, "params": {...}}`.
  Mutations require `documentId` and `expectedRevision`; both are checked inside the handler and
  a mismatch is `conflict` with the current values in the message. Reads accept them optionally
  and check them if present.
- **Response.** `{"ok": true, "result": ...}` or `{"ok": false, "error": {"code", "message"}}`.
  Codes: `conflict`, `not_found`, `invalid_address`, `invalid_argument`, `unsupported`, `io`.
- **Commands.** `get_active_document`, `list_elements`, `get_element`, `resolve_grid`,
  `view_base_image`, `get_history`, `create_element`, `update_element`, `delete_elements`,
  `set_crop`, `set_grid_density`, `undo`, `redo`, `save_project`, `export`, `batch`.
  Every mutation returns the new `revision`; element mutations return the full element.
- **Element JSON.** Agent-facing, not the Codable enum shape: `{"id", "type", "bounds", "color",
  ...per-type fields}` with points as `{"x","y"}` and colors as `#RRGGBB` (or `#RRGGBBAA`).
  Types: `arrow`, `line`, `rectangle`, `ellipse`, `pen`, `text`, `callout`, `stamp`,
  `pixelate`, `magnifier`. Input accepts either pixel geometry (`start`/`end`, `rect`,
  `center`, `points`) or grid addresses (`from`/`to` cells for arrows and lines, `over` a range
  for boxes, `at` a cell for stamps and text, `tail` a cell for callouts), resolved through the
  document's grid at call time.
- **Attribution.** The service sets the controller's commit attribution (actor, reason) around
  each mutation; `HistoryEntry` gains `reason`. Undo and redo through the service are commits
  attributed to the agent.
- **Batch.** All commands apply inside one document change; any failure leaves the document
  untouched and returns that command's error with its index.
- **Files.** `view_base_image` writes a PNG crop of the untouched base image under the app's
  Caches directory and returns the path; `export` and `save_project` take absolute paths.
  Tests cover every command, each error code, batch atomicity, attribution in history, and
  that a base-image crop carries no annotations.

## Commit 2: Apple Events

- `Masume.sdef` in Resources: application property `active document`; document class with
  read-only `id`, `revision`, `name`, `canvas width`, `canvas height`, `grid columns`,
  `grid rows`, `grid version`, `dirty`; one verb `execute` taking a JSON string and returning a
  JSON string. `NSAppleScriptEnabled` and `OSAScriptingDefinition` in Info.plist.
- `NSScriptCommand` subclass for `execute` that calls the service on the active tab, on the main
  actor. Malformed JSON is the only Apple Event error; everything else is an envelope.
- Integration test script (`scripts/ae-roundtrip.sh`) against the built app: read properties,
  a create, a conflict, a crop. Excluded from `swift test`.

## Commit 3: the `masume` CLI (Swift executable target)

- Offline: `info <file.masume>`, `export <file.masume> <out> [--format] [--bounds]`,
  `resolve --file <file.masume> <address>`, `new <image-or-pdf> <file.masume> [--page N]`.
  Through the model and renderer libraries; refuses with `conflict` when the app has the file
  open (a recovery package binds it).
- Live: `doc`, `elements`, `element <id>`, `resolve <address>`, `view <range> --out`,
  `history`, `add <type> ...`, `update <id> ...`, `delete <id>...`, `crop ...`, `density <n>`,
  `undo`, `redo`, `save [path]`, `export <path>`, `exec '<json>'`. Each is one Apple Event built
  with `NSAppleEventDescriptor` (no `osascript`). `--doc` and `--revision` default to the active
  document's current values, printed in the result.
- Output: the envelope on stdout; `--pretty`. Exit codes: 0 ok, 2 conflict, 3 not_found,
  4 invalid_address, 5 invalid_argument, 6 unsupported, 7 io, 10 Masume not running,
  64 usage. A table test in the unit suite checks that every live subcommand produces the same
  request JSON the MCP server produces.

## Commit 4: the MCP server (TypeScript, `mcp/`)

- `@modelcontextprotocol/sdk`; tools `masume_*` one-to-one with commands; each tool call spawns
  `masume exec` with the request JSON and returns the envelope (image content for
  `view_base_image`, file deleted after reading).
- stdio by default; `--http <port>` adds Streamable HTTP on loopback with a bearer token
  (printed once or `--token`) and `Origin` validation.
- Node tests with a fake `masume` on `PATH`.

## Commit 5: the round trip

- `scripts/roundtrip.sh`: build the app, launch it with a fixture image, then from a shell: read
  the document, resolve `B3` and `D6`, add an arrow, read it back, undo, redo, kill the app,
  relaunch, and read the document again. Acceptance criteria 6, 7, 10, and 11.
