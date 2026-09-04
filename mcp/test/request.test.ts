import test from "node:test";
import assert from "node:assert/strict";
import { buildRequest } from "../src/request.js";

const actor = { actorId: "nova", actorName: "Nova" };
const m = { documentId: "D", expectedRevision: 3, reason: "why" };

// The same rows as Tests/MasumeCLITests/CLITests.swift: one vocabulary.
const table: Array<[string, Record<string, unknown>, string, Record<string, unknown>]> = [
  ["masume_get_active_document", {}, "get_active_document", {}],
  ["masume_list_elements", {}, "list_elements", {}],
  ["masume_get_element", { id: "abc" }, "get_element", { id: "abc" }],
  ["masume_resolve_grid", { address: "d5:f7" }, "resolve_grid", { address: "d5:f7" }],
  ["masume_view_base_image", { range: "B2:C3", margin: 8 }, "view_base_image", { range: "B2:C3", margin: 8 }],
  ["masume_read_text", { range: "zone", languages: ["en-US"], customWords: ["Masume"] }, "read_text",
    { range: "zone", languages: ["en-US"], customWords: ["Masume"] }],
  ["masume_get_history", { limit: 5 }, "get_history", { limit: 5 }],
  ["masume_create_element", { ...m, element: { type: "arrow", from: "B3", to: "D6", color: "blue", width: 12 } },
    "create_element", { type: "arrow", from: "B3", to: "D6", color: "blue", width: 12 }],
  ["masume_update_element", { ...m, id: "abc", changes: { color: "red", zOrder: "front", start: { x: 5, y: 5 } } },
    "update_element", { id: "abc", color: "red", zOrder: "front", start: { x: 5, y: 5 } }],
  ["masume_delete_elements", { ...m, ids: ["a", "b"] }, "delete_elements", { ids: ["a", "b"] }],
  ["masume_set_crop", { ...m, crop: "B2:E5" }, "set_crop", { crop: "B2:E5" }],
  ["masume_set_crop", { ...m, crop: null }, "set_crop", { crop: null }],
  ["masume_set_grid_density", { ...m, cellsAcrossLongSide: 24 }, "set_grid_density", { cellsAcrossLongSide: 24 }],
  ["masume_undo", m, "undo", {}],
  ["masume_redo", m, "redo", {}],
  ["masume_save_project", { path: "/tmp/x.masume" }, "save_project", { path: "/tmp/x.masume" }],
  ["masume_export", { path: "/tmp/out.png", format: "png", bounds: "clipToImage" }, "export",
    { path: "/tmp/out.png", format: "png", bounds: "clipToImage" }],
];

test("every tool builds its command with the same params as the CLI", () => {
  for (const [tool, args, command, params] of table) {
    const request = buildRequest(tool, args, actor);
    assert.equal(request.command, command, tool);
    assert.deepEqual(request.params, params, tool);
  }
});

test("mutations carry document, revision, actor, and reason; reads carry none", () => {
  const create = buildRequest("masume_create_element", { ...m, element: { type: "line", from: "A1", to: "B2" } }, actor);
  assert.equal(create.documentId, "D");
  assert.equal(create.expectedRevision, 3);
  assert.equal(create.actorId, "nova");
  assert.equal(create.actorName, "Nova");
  assert.equal(create.reason, "why");
  const doc = buildRequest("masume_get_active_document", {}, actor);
  assert.equal(doc.documentId, undefined);
  assert.equal(doc.actorId, undefined);
  assert.throws(() => buildRequest("masume_frobnicate", {}, actor));
});
