// Tool call -> command request. A strict mirror of the command service's
// vocabulary; the masume CLI builds the same objects and the two are
// checked against one table. Nothing is added on the way.

export interface Actor {
  actorId: string;
  actorName: string;
}

export interface Request {
  command: string;
  params: Record<string, unknown>;
  documentId?: string;
  expectedRevision?: number;
  actorId?: string;
  actorName?: string;
  reason?: string;
}

export const MUTATIONS = new Set([
  "create_element", "update_element", "delete_elements", "set_crop", "set_grid_density", "batch", "undo", "redo",
]);

/** Common fields of every mutating tool call. */
export interface MutationArgs {
  documentId: string;
  expectedRevision: number;
  reason?: string;
}

function mutation(command: string, params: Record<string, unknown>, args: MutationArgs, actor: Actor): Request {
  return {
    command,
    params,
    documentId: args.documentId,
    expectedRevision: args.expectedRevision,
    actorId: actor.actorId,
    actorName: actor.actorName,
    ...(args.reason !== undefined ? { reason: args.reason } : {}),
  };
}

function read(command: string, params: Record<string, unknown> = {}, documentId?: string): Request {
  return documentId === undefined ? { command, params } : { command, params, documentId };
}

/** The request for a tool name and its validated arguments. */
export function buildRequest(tool: string, args: Record<string, unknown>, actor: Actor): Request {
  const a = args as Record<string, any>;
  const m = a as MutationArgs;
  switch (tool) {
    case "masume_get_active_document": return read("get_active_document", {}, a.documentId);
    case "masume_list_elements": return read("list_elements", {}, a.documentId);
    case "masume_get_element": return read("get_element", { id: a.id }, a.documentId);
    case "masume_resolve_grid": return read("resolve_grid", { address: a.address }, a.documentId);
    case "masume_view_base_image":
      return read("view_base_image", {
        ...(a.range !== undefined ? { range: a.range } : {}),
        ...(a.margin !== undefined ? { margin: a.margin } : {}),
      }, a.documentId);
    case "masume_get_history":
      return read("get_history", a.limit !== undefined ? { limit: a.limit } : {}, a.documentId);
    case "masume_create_element": return mutation("create_element", a.element, m, actor);
    case "masume_update_element": return mutation("update_element", { id: a.id, ...a.changes }, m, actor);
    case "masume_delete_elements": return mutation("delete_elements", { ids: a.ids }, m, actor);
    case "masume_set_crop": return mutation("set_crop", { crop: a.crop ?? null }, m, actor);
    case "masume_set_grid_density":
      return mutation("set_grid_density", { cellsAcrossLongSide: a.cellsAcrossLongSide }, m, actor);
    case "masume_undo": return mutation("undo", {}, m, actor);
    case "masume_redo": return mutation("redo", {}, m, actor);
    case "masume_batch": return mutation("batch", { commands: a.commands }, m, actor);
    case "masume_save_project":
      return read("save_project", a.path !== undefined ? { path: a.path } : {}, a.documentId);
    case "masume_export":
      return read("export", {
        path: a.path,
        ...(a.format !== undefined ? { format: a.format } : {}),
        ...(a.bounds !== undefined ? { bounds: a.bounds } : {}),
      }, a.documentId);
    default:
      throw new Error(`unknown tool ${tool}`);
  }
}
