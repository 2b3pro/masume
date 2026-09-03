#!/usr/bin/env node
// masume-mcp [--http <port>] [--token <token>] [--actor-id <id>] [--actor-name <name>]

import { serveHttp, serveStdio } from "./server.js";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const actor = { actorId: arg("--actor-id") ?? "agent", actorName: arg("--actor-name") ?? "Agent" };
const httpPort = arg("--http");

if (httpPort !== undefined) {
  const port = Number(httpPort);
  if (!Number.isInteger(port) || port < 0) {
    console.error("usage: masume-mcp --http <port> [--token <token>]");
    process.exit(64);
  }
  serveHttp(actor, { port, token: arg("--token") }).then(({ token, port }) => {
    console.error(`masume-mcp listening on http://127.0.0.1:${port}/ (Streamable HTTP)`);
    console.error(`Authorization: Bearer ${token}`);
  });
} else {
  serveStdio(actor).catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
