# masume-mcp

The MCP server for [Masume](../README.md). Tools map one-to-one onto the app's command
service; each call runs `masume exec '<json>'` and returns the envelope, so the server keeps
no document state and implements no document logic. Install the CLI first
(`bash scripts/install-cli.sh`) or point `MASUME_CLI` at the binary.

```sh
cd mcp && npm install && npm run build
node dist/src/index.js                     # stdio, for hosts that spawn the server
node dist/src/index.js --http 8722         # Streamable HTTP on 127.0.0.1:8722, token printed once
node dist/src/index.js --actor-id nova --actor-name Nova
```

Claude Code, stdio:

```json
{ "mcpServers": { "masume": { "command": "node", "args": ["/path/to/masume/mcp/dist/src/index.js", "--actor-id", "nova", "--actor-name", "Nova"] } } }
```

Streamable HTTP binds to loopback only, requires `Authorization: Bearer <token>` (generated at
start or given with `--token`), and rejects a non-local `Origin`, so the objections to an
in-app port do not apply. The app itself opens no port.

The handshake carries short server instructions, and `masume_guide` returns the agent's guide
(session shape, grid grammar, element fields, error codes, token-saving habits); both live in
`src/guide.ts`. An agent should read the guide once per session.

Tools: `masume_guide`, `masume_get_active_document`, `masume_list_elements`, `masume_get_element`,
`masume_resolve_grid`, `masume_view_base_image` (returns the PNG as image content),
`masume_set_zone` (a region marked out for the person, and readable back as the address `zone`),
`masume_get_history`, `masume_create_element`, `masume_update_element`,
`masume_delete_elements`, `masume_set_crop`, `masume_set_grid_density`, `masume_undo`,
`masume_redo`, `masume_batch`, `masume_save_project`, `masume_export`. Mutations take
`documentId` and `expectedRevision` from `masume_get_active_document` and fail closed with
`conflict` if either moved; give a short `reason`, it shows in the history panel.
