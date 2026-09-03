// Runs the masume CLI for one request and returns the envelope. The server
// keeps no document state and implements no document logic: every call is
// `masume exec '<json>'`, and the CLI's own exit codes are folded into the
// envelope (the CLI prints one even when it fails).

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { Request } from "./request.js";

const run = promisify(execFile);

export interface Envelope {
  ok: boolean;
  result?: unknown;
  error?: { code: string; message: string };
}

/** Path of the CLI: MASUME_CLI, else `masume` on PATH. */
export function cliPath(): string {
  return process.env.MASUME_CLI ?? "masume";
}

export async function executeRequest(request: Request): Promise<Envelope> {
  const json = JSON.stringify(request);
  let stdout = "";
  try {
    const result = await run(cliPath(), ["exec", json], { maxBuffer: 64 * 1024 * 1024 });
    stdout = result.stdout;
  } catch (error: any) {
    // A non-zero exit still carries the envelope on stdout.
    stdout = typeof error?.stdout === "string" ? error.stdout : "";
    if (!stdout.trim()) {
      const message = error?.code === "ENOENT"
        ? `the masume CLI was not found at ${cliPath()}; install it with scripts/install-cli.sh or set MASUME_CLI`
        : `masume failed: ${error?.message ?? String(error)}`;
      return { ok: false, error: { code: "io", message } };
    }
  }
  try {
    return JSON.parse(stdout) as Envelope;
  } catch {
    return { ok: false, error: { code: "io", message: `unreadable reply from masume: ${stdout.slice(0, 200)}` } };
  }
}
