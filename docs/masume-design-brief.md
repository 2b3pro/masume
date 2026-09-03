# Masume

**One human, one agent, one grid.**

Design brief, composed 2026-09-02 from the founding discussion. Companion to the executable spec in `agent-collaborative-annotation-spec.md`. That document says what done looks like and how it is verified. This one says what Masume is and why it is shaped this way.

---

## Executive Overview

Masume is a native macOS annotation workspace that a person and an AI agent share. The person marks up a screenshot through a Skitch-like canvas. The agent marks up the same document through MCP when it is collaborating live, or through the `masume` command line when a script or scheduler is driving. Both of them point at the image using the same language, a spreadsheet grid laid over the pixels: `D5` is a cell, `D5:F14` is a region, and either participant can say "put an arrow from B3 to D6" and mean exactly the same thing.

The editable project is the source of truth. Flattened PNG, JPEG, WebP, and PDF are exports, never the document. Every committed edit, from either participant, lands in one attributed history with one shared undo stack, autosaves immediately, and survives a crash.

Why it matters: agents are increasingly the ones reading screenshots and the ones asked to explain them. Today they work by describing pixel coordinates or by regenerating whole images. Masume gives them a durable, editable, human-legible annotation layer, and gives the human a way to see, correct, and undo what the agent did.

## Context and Genesis

Masume grew out of a fork of tk3fftk's Kakico, a fast, minimal Skitch alternative for Apple Silicon. The fork's first job was cosmetic: shadowed arrows, haloed text, icon-pin stamps, a pen that doubles as a highlighter. That work continues in the fork and has been offered upstream.

The second job turned out to be a different product. The moment the requirements included an editable project format, a spatial addressing language, an agent surface, and history with actor attribution, the thesis had diverged from upstream, which is deliberately shrinking and had removed native project saving on purpose. Keeping the name would also have collided on a single Mac: same bundle identifier, same file association for the project package, same Apple Event target name. So the product was renamed before any of those identifiers shipped, and the fork was left alone to stay a Skitch alternative.

The name is 升目, masume, a grid square. It keeps the Japanese lineage of the original and names the thing that makes the product work.

Audience: people who already use an annotation tool and are starting to hand screenshots to agents, and the agents themselves. The opportunity is the gap between "describe this screenshot" and "mark this up with me."

## Concept Essence

The governing principle is **a shared spatial language over an immutable image**.

- The base image never changes. Annotations sit above it. Export is the only place flattening happens.
- The grid is chrome, not content. It is drawn for humans and resolved for agents, and it never appears in an export.
- Addresses are deterministic. The same image always gets the same default grid, computed from its pixel dimensions alone, and the chosen counts are stored so nothing ever drifts.
- Observation and annotation are separate acts. An agent asked to look at a region sees the untouched base image, never the composited layer, and looking never leaves a trace in the document.
- Both participants are peers in history. Undo reverses the latest committed action regardless of who made it. The history panel says who did what in plain words.

The tone is exact and unhurried. The product refuses to guess: invalid addresses fail with a message, stale revisions fail closed, nothing is silently clamped.

## Structural Framework

Three layers already exist and are kept:

- `AnnotationModel`: pure value types. Document, annotations with stable UUIDs, image-space geometry, crop. The grid definition and the address parser and resolver live here, with no UI imports.
- `AnnotationRender`: Core Graphics rendering of a document into a flat image. Exports come from here, and so do base-image crops for agent observation.
- The app: SwiftUI shell, AppKit canvas, one `CanvasController` per tab, snapshot undo.

One new hub joins them: a **command service** extracted from the controller, with JSON-codable commands and results. Every way of driving the document is a thin client of that service.

- The canvas UI calls it directly.
- An Apple Event verb, `execute`, takes a JSON command and returns a JSON envelope. The app ships a scripting definition, so Script Editor, Automator, and JXA reach the service with nothing in between. Apple Events were chosen over a localhost port because they serialize on the main run loop, are gated by macOS Automation permission, and keep the protocol work out of Swift.
- A `masume` command-line tool, a Swift target in the same package, is the second client. Live, each subcommand is one Apple Event to the running app and prints the envelope, with exit codes that mirror the error codes so shell scripts can branch. Offline, it opens a project or an image with the model and renderer libraries and can inspect, resolve grid addresses, and export with the app closed. It adds no logic of its own: whatever a shell can do, MCP and AppleScript can do by the same name.
- The MCP server is a separate TypeScript process that spawns the CLI for every tool call and keeps no state. It speaks stdio by default and Streamable HTTP on request, the latter loopback-only with a bearer token and Origin checks, so a long-lived or remote agent session can connect without the app ever opening a port of its own. Riding on the CLI keeps the MCP protocol in the maintained TypeScript SDK and gives macOS a stable, signed binary to attach the Automation grant to. 🧩 [Assumed Specification] The MCP server lives in this repository under its own directory and is published as an npm-style package for the agent host to spawn.
- App Intents expose a small subset to Shortcuts, Siri, and Spotlight, carrying a `shortcuts` actor.
- An optional on-device command bar, built on Foundation Models, turns a typed phrase into a schema-valid command struct and routes it through the same validation.

The grid algorithm in one breath: tier the long side of the image in pixels to 8, 12, 16, 24, or 32 cells; derive columns and rows so cells are near-square and cover the image exactly with no partial row; compute edges as integer products divided last so they are exact; letters are bijective base 26. Density presets use the same tiers, and changing density bumps a stored grid version that invalidates any cached semantic map.

The project package, `.masume`, is a directory with a manifest, the lossless base image, a preview, and an append-only history. Saves are atomic. Opening verifies the manifest, checksum, dimensions, and IDs before touching the canvas.

## Behavioral and Experiential Design

The canonical arc is the round trip, and it is also the acceptance test:

1. The person pastes a screenshot. It autosaves to recovery immediately, before any project path exists.
2. The agent asks for the active document and receives its identity, revision, canvas size, and grid.
3. The agent resolves `B3` and `D6`, adds an arrow between their centers, and gives a one-line reason. The history panel shows the agent's name and the reason.
4. The person drags the arrow. The agent reads the updated object and sees the new geometry.
5. Either of them presses undo. The arrow returns to where the agent put it. Either presses redo.
6. The app is killed. On relaunch the document is exactly where the last commit left it.

Smaller moments that carry the feel:

- Toggling the grid shows column letters across the top and row numbers down the left, thinning as you zoom out. Selection handles stay above the grid, and the grid never intercepts a click.
- The agent's presence is a quiet connection indicator, not a cursor flying around the canvas.
- The first time a project is saved, the app says plainly that the package contains the original unredacted image and is not a safe thing to share. The share-safe path is a separate command with an unambiguous name.
- When the agent asks to look at `D5:F14`, the person sees nothing change. Observation is invisible by design.

## Aesthetic Language and Semiotic Intent

The visual register is inherited and intentional: Skitch's warmth, where arrows cast soft shadows that scale with stroke width, text wears a halo or an outline, and stamps are pins with tails. The chrome uses the Miro-style token set already in the codebase.

The grid borrows the semiotics of a spreadsheet on purpose. Letters and numbers are the most widely understood coordinate system that ordinary people already speak fluently, and they compress well in a prompt. 🪞 [Assumed Interpretation] Grid lines should read as a light guide, closer to graph paper than to a cage, and labels should sit in the margin the way a ruler does, so the image remains the subject.

History entries are written as sentences, "Nova added arrow 4F2A," because the panel is a conversation log between two collaborators, not an audit table.

## Design Sensibility

Masume is built on three postures.

**Determinism over convenience.** A viewport-derived grid would have been slightly nicer on first display and impossible to reason about. Tiers won because a grid you can predict from the image alone is a language; a grid that depends on the window is a coincidence.

**Fail closed, say why.** Wrong document, stale revision, reversed range, unsupported style: each returns a named error and changes nothing. The product would rather be corrected than be wrong quietly.

**Honesty about what a file contains.** An editable project necessarily holds the unredacted original. The design does not hide that behind encryption theater; it names it at the moment it becomes true and offers the flattened alternative in the same breath.

The voice throughout is the voice of the discussion that produced it: direct, a little dry, unwilling to over-explain, and quick to name the one decision that is actually the user's to make.

## Ethical, Practical, and Operational Notes

- **Redaction.** Pixelation hides content only in exports. The project package must never be mistaken for a redacted deliverable; Finder metadata, Quick Look, and save-time copy all say so.
- **Privacy of the image.** Base-image observation goes to whatever model the agent host uses; that is the agent's choice, not Masume's. The on-device features (Vision text mapping, Foundation Models command bar) never send pixels off the machine, and Private Cloud Compute is not used for document content.
- **Provenance.** Upstream Kakico has no license file. The model, renderer, and canvas remain Hiroki Takatsuka's all-rights-reserved code until a license is added upstream. Masume's own contributions are MIT. Binaries are not redistributed until that is resolved, and attribution stays in the README and LICENSE regardless of how far the code drifts.
- **Automation permission.** macOS keys Automation grants to the calling binary's path; version-pathed runtimes lose the grant on upgrade. The signed `masume` CLI at a stable install path is the binary that holds the grant, and the MCP server spawns it rather than `osascript`.
- **Latency.** Each live call is one Apple Event plus a process start, roughly a few hundred milliseconds. Batch commands exist for that reason, and a Unix-socket transport over the same service is the designated relief valve; the CLI and the MCP server would move to it together.
- **Deployment target.** The codebase targets macOS 15. Vision text mapping works there. The Foundation Models command bar and Apple Intelligence assistant surfaces need macOS 26 and a deliberate target decision.
- **Constraint kept from the original.** No third-party packages beyond libwebp. This is part of why the MCP protocol lives in TypeScript, not Swift.

## Implementation Roadmap

1. **Durable document.** Versioned `.masume` package codec, dirty tracking, Save and Save As, atomic writes, recovery autosave, redaction disclosure, share-safe export.
2. **Shared spatial language.** Stored grid definition, pure address parser and resolver, non-exporting overlay with labels, density presets, tests across aspect ratios and tier boundaries.
3. **Agent surfaces.** Extract the command service; add the scripting definition and `execute` verb with revision assertions; add the `masume` CLI, offline commands first and then the live mirror; add the TypeScript MCP server on top of the CLI; prove the round trip end to end from MCP and from a shell, and across a restart.
4. **Remaining vocabulary.** Rounded rectangles, translucent highlights, freehand paths, numbered callouts, shadows with per-object override, session style memory.
5. **On-device intelligence, optional.** Vision text mapping first; the Foundation Models command bar and App Intents after the target decision.

Version one is complete when all ten acceptance criteria in the spec are demonstrably true, with the round trip passing both automated tests and a manual smoke test.

## Open Questions and Further Inquiry

- Bump the deployment target to macOS 26 for v1, or ship the command bar behind availability guards?
- Sub-cell addressing shipped 2026-09-02: `D5.3` is a quadrant (1 to 4 clockwise from the upper left) and quadrants nest to four levels, so a coarse cell on a 4K capture no longer forces pixel coordinates.
- The Automation-grant helper question is settled by the CLI: `masume` is the signed, stably installed binary. Whether PAI's other tools should adopt the same pattern (a per-app CLI that MCP spawns) is a PAI question, not a Masume one.
- A full scriptable object model (native `annotation` classes, `whose` filters) is deferred. What signal would justify building it?
- A terminal database client on GitHub already uses the name masume in an unrelated domain. Revisit if Masume ever ships publicly.
- Upstream licensing remains the gate on distributing binaries. Is it worth a direct ask beyond the open issue?

---

**Quick-Start Context String**

We're building Masume: a native macOS annotation workspace where a person and an agent mark up the same immutable image through one editable project, speaking a deterministic spreadsheet grid as their shared spatial language, with every edit attributed, undoable by either, and autosaved, and with one in-app command service behind three thin clients (MCP for live collaboration, a `masume` CLI for automation, AppleScript for everything on the Mac), so that collaboration with an agent on a screenshot feels as ordinary and as trustworthy as editing a document together.
