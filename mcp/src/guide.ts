// The agent's guide to Masume: one source, served two ways. INSTRUCTIONS
// goes out with the MCP handshake so a host that shows server instructions
// gets the essentials for free; GUIDE is the masume_guide tool's answer,
// meant to be read once per session. Both are written to be cheap: no
// prose the agent does not act on.

export const INSTRUCTIONS = `Masume: annotate the image a person has open, on the same canvas, undo stack, and history they see.
Call masume_guide once per session for the workflow, grid grammar, element fields, and errors.
Start with masume_get_active_document; every mutation needs its id and revision and returns the next revision.
Point with grid addresses (D5 cell, D5.3 quadrant, D5:F14 range), look with masume_view_base_image by range, and give each edit a short reason.`;

export const GUIDE = `# Masume for agents

One person and one agent mark up the same image. Your edits land in the person's undo stack and history, attributed to you with the reason you give. Keep reasons short and specific ("point at the Save button").

## Session shape
1. masume_get_active_document: id, revision, canvas size, grid (columns x rows), crop, selection. Nothing open is not_found; ask the person to open or paste an image.
2. Look only where you need to. masume_view_base_image with a range ("C4:F9", margin 20) is far cheaper than the whole image. The base image never shows annotations; masume_list_elements does.
3. Point with grid addresses, not pixels. D5 is a cell, D5.3 a quadrant (1 to 4 clockwise from the upper left; nest as D5.3.1), D5:F14 a range. masume_resolve_grid gives pixels when you need numbers. Addresses are exact; nothing clamps.
4. Mutate with documentId and expectedRevision. Each mutation returns the new revision: carry it forward, do not re-read. A conflict means the person edited meanwhile: re-read the document, look again, then retry with intent.
5. Related edits go in masume_batch: one atomic commit, one undo step for the person.

## Elements
masume_create_element { element: { type, ...geometry, ...style } }   masume_update_element { id, changes: { ... } }   masume_delete_elements { ids }
types: arrow line rectangle ellipse pen text callout stamp pixelate magnifier
geometry by address: from/to (arrow, line) | over (rectangle, ellipse, pixelate, magnifier) | at (text origin, stamp center) | tail (callout tail cell)
geometry by pixels: start/end | rect | center | tailTip | points (pen)
style: color (palette name or #RRGGBB), width, fill, opacity (pen, below 1 is a highlighter)
text, callout: text, fontSize, bold, alignment left|center|right, style shadow|outline|plain; callout also shape speech|thought
stamp: kind check|cross|exclaim|question|heart|number|letter|emoji, radius, pointerAngle; number/letter take ordinal (default: next of that kind), emoji takes emoji
pixelate: amount (block size)   magnifier: zoom 1.5 to 8, shape circle|square
update only: zOrder front|back
Every element comes back with id, type, bounds, color, and its own fields; ids are stable.

## Other tools
masume_get_element (id), masume_get_history (limit), masume_set_crop (rect, range, or null), masume_set_grid_density (8 12 16 24 32 across the long side; changes every address), masume_undo, masume_redo (either side's actions), masume_save_project (absolute .masume path first time; holds the unredacted original), masume_export (absolute png/jpeg/webp path; bounds expandToFit|clipToImage).

## Errors
conflict (revision moved), not_found, invalid_address, invalid_argument, unsupported, io. The message says what to fix; the document is unchanged.

## Habits that save tokens
- One masume_get_active_document at the start, then trust returned revisions.
- View by range with a margin instead of widening the range or fetching the whole image.
- List elements once; afterwards use the element each mutation returns, or masume_get_element by id.
- Batch multi-step work; do not re-list after every edit.
- Prefer a denser grid (masume_set_grid_density) over pixel coordinates when cells are too coarse, and quadrants over density when one spot needs precision.`;
