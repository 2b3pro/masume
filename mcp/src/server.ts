// The Masume MCP server: tools one-to-one with the command service, each
// forwarded through the masume CLI. Two transports over the same tools:
// stdio (the default, for hosts that spawn the server) and Streamable HTTP
// (opt-in, loopback only, bearer token, Origin checked).

import { readFile, unlink } from "node:fs/promises";
import { createRequire } from "node:module";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { randomBytes } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { GUIDE, INSTRUCTIONS } from "./guide.js";
import { buildRequest, type Actor } from "./request.js";
import { executeRequest, type Envelope } from "./masume.js";

const mutationShape = {
  documentId: z.string().describe("The document's id, from masume_get_active_document."),
  expectedRevision: z.number().int().describe("The revision you last read; the call fails closed if it moved."),
  reason: z.string().optional().describe("A short reason for the history panel."),
};
const docShape = { documentId: z.string().optional().describe("Assert the active document's id.") };

const point = z.object({ x: z.number(), y: z.number() });
const rect = z.object({ x: z.number(), y: z.number(), width: z.number(), height: z.number() });

/** Geometry by grid address or pixels, plus style; see the element JSON in the spec. */
const elementInput = z.object({
  type: z.enum(["arrow", "line", "rectangle", "ellipse", "pen", "text", "callout", "stamp", "pixelate", "magnifier"]),
  from: z.string().optional().describe("Cell for an arrow's or line's start, e.g. B3, or a quadrant of it, e.g. B3.3 (1 to 4 clockwise from the upper left; nests as B3.3.1)."),
  to: z.string().optional(),
  over: z.string().optional().describe("Range for a box, e.g. D5:F14 or D5.3:F14."),
  at: z.string().optional().describe("Cell for a stamp's center or a text box's origin."),
  tail: z.string().optional().describe("Cell a callout's tail points at."),
  start: point.optional(), end: point.optional(), rect: rect.optional(), center: point.optional(),
  tailTip: point.optional(), points: z.array(point).optional(),
  color: z.string().optional().describe("Palette name or #RRGGBB."), fill: z.string().optional(),
  width: z.number().optional(), opacity: z.number().optional(),
  text: z.string().optional(), fontSize: z.number().optional(), bold: z.boolean().optional(),
  alignment: z.enum(["left", "center", "right"]).optional(), style: z.enum(["shadow", "outline", "plain"]).optional(),
  outlineColor: z.string().optional(), shape: z.string().optional(),
  kind: z.string().optional().describe("Stamp glyph: check, cross, exclaim, question, heart, number, letter, or emoji. number and letter show `ordinal` (1 = \"1\" or \"A\"), defaulting to one past the highest of that kind; emoji shows `emoji`."),
  ordinal: z.number().int().optional().describe("The count a number or letter stamp shows, 1 to 999."),
  emoji: z.string().optional().describe("The single character an emoji stamp shows, e.g. \"🔥\"."),
  zoom: z.number().optional(), amount: z.number().optional(), radius: z.number().optional(),
  pointerAngle: z.number().optional(),
}).passthrough();

export function toolResult(envelope: Envelope) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(envelope) }],
    isError: !envelope.ok,
  };
}

/** A base-image crop: the PNG as image content plus the metadata, file removed. */
async function cropResult(envelope: Envelope) {
  const result = envelope.result as { path?: string } | undefined;
  if (!envelope.ok || !result?.path) return toolResult(envelope);
  const data = await readFile(result.path);
  await unlink(result.path).catch(() => undefined);
  const { path: _dropped, ...meta } = result;
  return {
    content: [
      { type: "image" as const, data: data.toString("base64"), mimeType: "image/png" },
      { type: "text" as const, text: JSON.stringify({ ok: true, result: meta }) },
    ],
  };
}

export function createMasumeServer(actor: Actor): McpServer {
  // The version is the package's (dist/src/ sits two levels under it).
  const { version } = createRequire(import.meta.url)("../../package.json") as { version: string };
  const server = new McpServer({ name: "masume", version }, { instructions: INSTRUCTIONS });
  const call = (tool: string) => async (args: Record<string, unknown>) =>
    toolResult(await executeRequest(buildRequest(tool, args, actor)));

  server.registerTool("masume_guide", {
    description: "How to work with Masume: the session shape, grid address grammar, element types and fields, error codes, and token-saving habits. Read once per session; it needs no running app.",
    inputSchema: {},
  }, async () => ({ content: [{ type: "text" as const, text: GUIDE }] }));
  server.registerTool("masume_get_active_document", {
    description: "The active document: id, revision, canvas size, grid, crop, selection, the zone the person marked out (rect, shape, covering grid range), dirty state, and counts. Read this first; mutations need its id and revision.",
    inputSchema: docShape,
  }, call("masume_get_active_document"));
  server.registerTool("masume_list_elements", {
    description: "Every annotation in draw order, as agent-facing JSON with stable ids.",
    inputSchema: docShape,
  }, call("masume_list_elements"));
  server.registerTool("masume_get_element", {
    description: "One annotation by id.",
    inputSchema: { ...docShape, id: z.string() },
  }, call("masume_get_element"));
  server.registerTool("masume_resolve_grid", {
    description: "A cell (D5), a quadrant of it (D5.3: 1 to 4 clockwise from the upper left, nesting as D5.3.1), a range (D5:F14), or \"zone\" (the region marked out on the canvas) to pixels: rect, center, corners, and normalized coordinates. Never clamps; a bad address is an error.",
    inputSchema: { ...docShape, address: z.string() },
  }, call("masume_resolve_grid"));
  server.registerTool("masume_view_base_image", {
    description: "The untouched base image, whole or by grid range (or \"zone\"), as PNG. Annotations never appear in it and looking leaves no trace.",
    inputSchema: { ...docShape, range: z.string().optional(), margin: z.number().optional().describe("Context margin in pixels.") },
  }, async (args) => cropResult(await executeRequest(buildRequest("masume_view_base_image", args, actor))));
  server.registerTool("masume_read_text", {
    description: "Recognize text locally in the untouched base image, whole or by grid range (or \"zone\"). Returns strings, confidence, pixel and normalized bounds, and covering grid ranges; never returns image data.",
    inputSchema: {
      ...docShape,
      range: z.string().optional(),
      languages: z.array(z.string()).optional().describe("Vision language identifiers such as en-US or fr-FR."),
      customWords: z.array(z.string()).optional().describe("Names or specialist terms Vision should preserve."),
    },
  }, call("masume_read_text"));
  server.registerTool("masume_set_zone", {
    description: "Mark a region out for the person as marching ants (a rect, a grid range, or null to clear), optionally as an ellipse. Not an annotation: never exported, no revision change. The person's own zone, drawn with the Select tool, is read from masume_get_active_document, and \"zone\" works as an address in any geometry parameter.",
    inputSchema: { ...docShape, zone: z.union([rect, z.string(), z.null()]), shape: z.enum(["rectangle", "ellipse"]).optional() },
  }, call("masume_set_zone"));
  server.registerTool("masume_get_history", {
    description: "Committed actions, oldest first, with actor, revisions, summary, reason, and affected ids.",
    inputSchema: { ...docShape, limit: z.number().int().optional() },
  }, call("masume_get_history"));

  server.registerTool("masume_create_element", {
    description: "Create an annotation. Geometry by grid address (from/to, over, at, tail) or pixels. Returns the element and the new revision.",
    inputSchema: { ...mutationShape, element: elementInput },
  }, call("masume_create_element"));
  server.registerTool("masume_update_element", {
    description: "Change only the given keys of an annotation (geometry, style, text, zOrder front|back).",
    inputSchema: { ...mutationShape, id: z.string(), changes: elementInput.partial().passthrough() },
  }, call("masume_update_element"));
  server.registerTool("masume_delete_elements", {
    description: "Delete annotations by id. Unknown ids fail the whole call.",
    inputSchema: { ...mutationShape, ids: z.array(z.string()).min(1) },
  }, call("masume_delete_elements"));
  server.registerTool("masume_set_crop", {
    description: "Set the non-destructive crop to a rect or a grid range, or clear it with null.",
    inputSchema: { ...mutationShape, crop: z.union([rect, z.string(), z.null()]) },
  }, call("masume_set_crop"));
  server.registerTool("masume_set_grid_density", {
    description: "Change the grid to a preset (8, 12, 16, 24, or 32 cells across the long side). Invalidates address-keyed caches.",
    inputSchema: { ...mutationShape, cellsAcrossLongSide: z.number().int() },
  }, call("masume_set_grid_density"));
  server.registerTool("masume_undo", {
    description: "Undo the latest committed action, whoever made it.",
    inputSchema: mutationShape,
  }, call("masume_undo"));
  server.registerTool("masume_redo", {
    description: "Redo the last undone action.",
    inputSchema: mutationShape,
  }, call("masume_redo"));
  server.registerTool("masume_batch", {
    description: "Several mutations as one atomic, undoable commit. Any failure leaves the document untouched.",
    inputSchema: {
      ...mutationShape,
      commands: z.array(z.object({ command: z.string(), params: z.record(z.unknown()).optional() })).min(1),
    },
  }, call("masume_batch"));
  server.registerTool("masume_save_project", {
    description: "Save the editable project (absolute path required the first time). The package contains the original, unredacted image.",
    inputSchema: { ...docShape, path: z.string().optional() },
  }, call("masume_save_project"));
  server.registerTool("masume_export", {
    description: "Write a flattened PNG, JPEG, or WebP to an absolute path; the document is unchanged.",
    inputSchema: { ...docShape, path: z.string(), format: z.enum(["png", "jpeg", "webp"]).optional(), bounds: z.enum(["expandToFit", "clipToImage"]).optional() },
  }, call("masume_export"));
  return server;
}

// MARK: transports

export async function serveStdio(actor: Actor): Promise<void> {
  const server = createMasumeServer(actor);
  await server.connect(new StdioServerTransport());
}

export interface HttpOptions {
  port: number;
  token?: string;
  host?: string;
}

const LOCAL_ORIGINS = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/;

/** Rejects requests that are not from this machine's own clients. */
export function checkHttpRequest(req: IncomingMessage, token: string): { ok: true } | { ok: false; status: number; message: string } {
  const origin = req.headers.origin;
  if (origin !== undefined && !LOCAL_ORIGINS.test(origin)) {
    return { ok: false, status: 403, message: "origin not allowed" };
  }
  if (req.headers.authorization !== `Bearer ${token}`) {
    return { ok: false, status: 401, message: "missing or wrong bearer token" };
  }
  return { ok: true };
}

/** Streamable HTTP on loopback. Stateless: each request gets its own server and transport. */
export async function serveHttp(actor: Actor, options: HttpOptions): Promise<{ close: () => void; token: string; port: number }> {
  const token = options.token ?? randomBytes(24).toString("base64url");
  const host = options.host ?? "127.0.0.1";
  const http = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const check = checkHttpRequest(req, token);
    if (!check.ok) {
      res.writeHead(check.status, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: check.message }));
      return;
    }
    let body: unknown;
    if (req.method === "POST") {
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(chunk as Buffer);
      try { body = JSON.parse(Buffer.concat(chunks).toString("utf8") || "null"); } catch { body = null; }
    }
    const server = createMasumeServer(actor);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    res.on("close", () => { transport.close(); server.close(); });
    await server.connect(transport);
    await transport.handleRequest(req, res, body);
  });
  await new Promise<void>((resolve) => http.listen(options.port, host, resolve));
  const address = http.address();
  const port = typeof address === "object" && address ? address.port : options.port;
  return { close: () => http.close(), token, port };
}
