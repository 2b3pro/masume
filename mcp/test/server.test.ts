import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, chmod, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { IncomingMessage } from "node:http";
import { Socket } from "node:net";
import { executeRequest } from "../src/masume.js";
import { checkHttpRequest, toolResult } from "../src/server.js";

async function fakeCli(script: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "masume-mcp-"));
  const path = join(dir, "masume");
  await writeFile(path, `#!/bin/sh\n${script}\n`);
  await chmod(path, 0o755);
  return path;
}

test("each call is masume exec with the request JSON, and the envelope comes back", async () => {
  process.env.MASUME_CLI = await fakeCli(`[ "$1" = exec ] || exit 64
printf '{"ok":true,"result":{"echo":%s}}' "$2"`);
  const envelope = await executeRequest({ command: "resolve_grid", params: { address: "A1" } });
  assert.equal(envelope.ok, true);
  assert.deepEqual((envelope.result as any).echo, { command: "resolve_grid", params: { address: "A1" } });
});

test("a failing CLI still yields its envelope, and a missing CLI is an io error", async () => {
  process.env.MASUME_CLI = await fakeCli(`printf '{"ok":false,"error":{"code":"conflict","message":"stale"}}'; exit 2`);
  const conflict = await executeRequest({ command: "undo", params: {} });
  assert.equal(conflict.ok, false);
  assert.equal(conflict.error?.code, "conflict");
  assert.equal(toolResult(conflict).isError, true);
  process.env.MASUME_CLI = "/nonexistent/masume";
  const missing = await executeRequest({ command: "undo", params: {} });
  assert.equal(missing.error?.code, "io");
  assert.match(missing.error!.message, /not found/);
});

function request(headers: Record<string, string>): IncomingMessage {
  const req = new IncomingMessage(new Socket());
  req.headers = headers;
  return req;
}

test("HTTP requests need the bearer token and a local origin", () => {
  assert.equal(checkHttpRequest(request({ authorization: "Bearer T" }), "T").ok, true);
  assert.equal(checkHttpRequest(request({ authorization: "Bearer T", origin: "http://localhost:3000" }), "T").ok, true);
  assert.equal(checkHttpRequest(request({ authorization: "Bearer T", origin: "http://127.0.0.1" }), "T").ok, true);
  const foreign = checkHttpRequest(request({ authorization: "Bearer T", origin: "https://evil.example" }), "T");
  assert.equal(foreign.ok, false);
  assert.equal((foreign as any).status, 403);
  const wrong = checkHttpRequest(request({ authorization: "Bearer nope" }), "T");
  assert.equal((wrong as any).status, 401);
  assert.equal((checkHttpRequest(request({}), "T") as any).status, 401);
});
