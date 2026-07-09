export interface Env {
  DB: D1Database;
}

interface MachineAuth {
  machine: string;
  readPrefixes: string[];
  writePrefixes: string[];
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const MAX_STATE_BYTES = 256 * 1024;
const MAX_REQUEST_BYTES = MAX_STATE_BYTES + 4096;
const MAX_STATE_PATH_BYTES = 512;
const MAX_LIST_LIMIT = 1000;
const STATE_PATH = /^(claims|heartbeats|batches|events)\/[A-Za-z0-9_.:/-]+\.json$/;
const STATE_PREFIX = /^(?:claims(?:\/[A-Za-z0-9_.:-]+(?:\/[A-Za-z0-9_.:-]+)?)?|heartbeats|batches|events(?:\/[A-Za-z0-9_.:-]+)?)$/;

function validPath(path: string): boolean {
  return new TextEncoder().encode(path).byteLength <= MAX_STATE_PATH_BYTES
    && STATE_PATH.test(path)
    && !path.includes("..")
    && !path.includes("//");
}

function validPrefix(prefix: string): boolean {
  return new TextEncoder().encode(prefix).byteLength <= MAX_STATE_PATH_BYTES
    && STATE_PREFIX.test(prefix)
    && !prefix.includes("..")
    && !prefix.includes("//");
}

function escapeLikePrefix(prefix: string): string {
  return prefix.replace(/[\\%_]/g, (value) => `\\${value}`);
}

function validScopePrefix(prefix: string): boolean {
  return prefix === "" || validPrefix(prefix) || validPath(prefix);
}

function exactStatePathScope(scope: string): boolean {
  if (!validPath(scope)) return false;
  const parts = scope.split("/");
  switch (parts[0]) {
    case "claims":
      return parts.length === 4;
    case "heartbeats":
    case "batches":
      return parts.length === 2;
    case "events":
      return parts.length === 3;
    default:
      return false;
  }
}

function parsePrefixList(value: string): string[] | null {
  try {
    const parsed = JSON.parse(value);
    if (!Array.isArray(parsed) || parsed.length === 0) return null;
    if (!parsed.every((item) => typeof item === "string" && validScopePrefix(item))) return null;
    return parsed;
  } catch {
    return null;
  }
}

async function authenticate(request: Request, env: Env): Promise<MachineAuth | null> {
  const header = request.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer (.+)$/i);
  if (!match) return null;
  const hash = await sha256Hex(match[1]);
  const row = await env.DB.prepare(
    "SELECT machine, read_prefixes, write_prefixes FROM machines WHERE token_hash = ? AND revoked_at IS NULL",
  ).bind(hash).first<{ machine: string; read_prefixes: string; write_prefixes: string }>();
  if (!row) return null;
  return {
    machine: row.machine,
    readPrefixes: parsePrefixList(row.read_prefixes) ?? [],
    writePrefixes: parsePrefixList(row.write_prefixes) ?? [],
  };
}

function scopeCoversPath(scope: string, path: string): boolean {
  if (scope === "") return true;
  if (path === scope) return true;
  return !exactStatePathScope(scope) && path.startsWith(`${scope}/`);
}

function scopeCoversListPrefix(scope: string, prefix: string): boolean {
  if (scope === "") return true;
  if (exactStatePathScope(scope)) return false;
  return prefix === scope || prefix.startsWith(`${scope}/`);
}

type ScopedListFilter = { kind: "directory"; scope: string } | { kind: "path"; scope: string };
type ListScopeFilter = { kind: "all" } | ScopedListFilter;

function listScopeFilter(scope: string, prefix: string): ListScopeFilter | null {
  if (scope === "") return { kind: "all" };
  if (scopeCoversListPrefix(scope, prefix)) return { kind: "all" };
  if (exactStatePathScope(scope)) {
    return scope.startsWith(`${prefix}/`) ? { kind: "path", scope } : null;
  }
  return scope.startsWith(`${prefix}/`) ? { kind: "directory", scope } : null;
}

function listScopeFilters(prefixes: string[], prefix: string): ScopedListFilter[] | null {
  const filters: ScopedListFilter[] = [];
  for (const scope of prefixes) {
    const filter = listScopeFilter(scope, prefix);
    if (!filter) continue;
    if (filter.kind === "all") return [];
    filters.push(filter);
  }
  return filters.length > 0 ? filters : null;
}

function canAccessPath(prefixes: string[], path: string): boolean {
  return prefixes.some((prefix) => scopeCoversPath(prefix, path));
}

async function readJsonBody(request: Request): Promise<{ body: unknown } | { response: Response }> {
  if (!request.body) return { response: json(400, { error: "invalid_json" }) };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > MAX_REQUEST_BYTES) {
      await reader.cancel();
      return { response: json(413, { error: "payload_too_large" }) };
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    return { body: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { response: json(400, { error: "invalid_json" }) };
  }
}

async function getState(env: Env, path: string): Promise<Response> {
  const row = await env.DB.prepare("SELECT data, version, updated_by FROM state WHERE path = ?")
    .bind(path).first<{ data: string; version: number; updated_by: string | null }>();
  if (!row) return json(404, { error: "not_found" });
  const body: { path: string; data: unknown; version: number; updated_by?: string } = {
    path,
    data: JSON.parse(row.data),
    version: row.version,
  };
  if (row.updated_by !== null) body.updated_by = row.updated_by;
  return json(200, body);
}

async function putState(request: Request, env: Env, path: string, machine: string): Promise<Response> {
  // Best-effort pre-parse guard; the serialized-data cap below still handles absent lengths.
  const contentLength = request.headers.get("content-length");
  if (contentLength && /^\d+$/.test(contentLength)) {
    const requestBytes = Number.parseInt(contentLength, 10);
    if (!Number.isSafeInteger(requestBytes) || requestBytes > MAX_REQUEST_BYTES) {
      return json(413, { error: "payload_too_large" });
    }
  }

  const bodyResult = await readJsonBody(request);
  if ("response" in bodyResult) return bodyResult.response;
  const body = bodyResult.body;
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return json(400, { error: "missing_data" });
  }
  const payload = body as { data?: unknown };
  if (payload.data === undefined) return json(400, { error: "missing_data" });
  const data = JSON.stringify(payload.data);
  if (new TextEncoder().encode(data).byteLength > MAX_STATE_BYTES) {
    return json(413, { error: "payload_too_large" });
  }
  const now = new Date().toISOString();
  const ifMatch = request.headers.get("if-match");
  const ifNoneMatch = request.headers.get("if-none-match");

  if (ifNoneMatch && ifNoneMatch !== "*") return json(400, { error: "invalid_if_none_match" });
  if (ifNoneMatch === "*") {
    const result = await env.DB.prepare(
      "INSERT INTO state (path, data, version, updated_at, updated_by) VALUES (?, ?, 1, ?, ?) ON CONFLICT (path) DO NOTHING",
    ).bind(path, data, now, machine).run();
    if (result.meta.changes === 0) return json(409, { error: "already_exists" });
    return json(201, { path, version: 1, updated_by: machine });
  }
  if (ifMatch) {
    if (!/^\d+$/.test(ifMatch)) return json(400, { error: "invalid_if_match" });
    const version = Number.parseInt(ifMatch, 10);
    if (!Number.isSafeInteger(version)) return json(400, { error: "invalid_if_match" });
    const result = await env.DB.prepare(
      "UPDATE state SET data = ?, version = version + 1, updated_at = ?, updated_by = ? WHERE path = ? AND version = ?",
    ).bind(data, now, machine, path, version).run();
    if (result.meta.changes === 0) return json(409, { error: "version_conflict" });
    return json(200, { path, version: version + 1, updated_by: machine });
  }
  return json(400, { error: "precondition_required" });
}

async function listState(
  env: Env,
  prefix: string,
  searchParams: URLSearchParams,
  auth: MachineAuth,
): Promise<Response> {
  if (!validPrefix(prefix)) {
    return json(400, { error: "invalid_prefix" });
  }
  const scopeFilters = listScopeFilters(auth.readPrefixes, prefix);
  if (scopeFilters === null) return json(403, { error: "forbidden" });
  const limitParam = searchParams.get("limit");
  let limit: number | null = null;
  if (limitParam !== null) {
    if (!/^\d+$/.test(limitParam)) return json(400, { error: "invalid_limit" });
    limit = Number.parseInt(limitParam, 10);
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_LIST_LIMIT) {
      return json(400, { error: "invalid_limit" });
    }
  }
  const cursor = searchParams.get("cursor");
  if (cursor !== null && (!validPath(cursor) || !cursor.startsWith(`${prefix}/`))) {
    return json(400, { error: "invalid_cursor" });
  }
  const clauses = ["path LIKE ? ESCAPE '\\'"];
  const binds: (string | number)[] = [`${escapeLikePrefix(prefix)}/%`];
  if (scopeFilters.length > 0) {
    const scopeClauses = scopeFilters.map((filter) => {
      if (filter.kind === "path") {
        binds.push(filter.scope);
        return "path = ?";
      }
      binds.push(`${escapeLikePrefix(filter.scope)}/%`);
      return "path LIKE ? ESCAPE '\\'";
    });
    clauses.push(`(${scopeClauses.join(" OR ")})`);
  }
  if (cursor !== null) {
    clauses.push("path > ?");
    binds.push(cursor);
  }
  let sql = `SELECT path, data, version, updated_by FROM state WHERE ${clauses.join(" AND ")} ORDER BY path`;
  if (limit !== null) {
    sql += " LIMIT ?";
    binds.push(limit + 1);
  }
  const rows = await env.DB.prepare(
    sql,
  ).bind(...binds).all<{ path: string; data: string; version: number; updated_by: string | null }>();
  let results = rows.results ?? [];
  let nextCursor: string | undefined;
  if (limit !== null && results.length > limit) {
    results = results.slice(0, limit);
    nextCursor = results[results.length - 1]?.path;
  }
  const entries = results.map((r) => ({
    path: r.path,
    data: JSON.parse(r.data),
    version: r.version,
    ...(r.updated_by === null ? {} : { updated_by: r.updated_by }),
  }));
  return json(200, nextCursor ? { entries, next_cursor: nextCursor } : { entries });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/v1/health") {
      return json(200, { status: "ok" });
    }
    const auth = await authenticate(request, env);
    if (!auth) {
      return json(401, { error: "unauthorized" });
    }
    if (url.pathname === "/v1/state") {
      if (request.method === "GET") {
        return listState(env, url.searchParams.get("prefix") ?? "", url.searchParams, auth);
      }
      return json(405, { error: "method_not_allowed" });
    }
    if (url.pathname.startsWith("/v1/state/")) {
      let path: string;
      try {
        path = decodeURIComponent(url.pathname.slice("/v1/state/".length));
      } catch {
        return json(400, { error: "invalid_path" });
      }
      if (!validPath(path)) return json(400, { error: "invalid_path" });
      if (request.method === "GET") {
        if (!canAccessPath(auth.readPrefixes, path)) return json(403, { error: "forbidden" });
        return getState(env, path);
      }
      if (request.method === "PUT") {
        if (!canAccessPath(auth.writePrefixes, path)) return json(403, { error: "forbidden" });
        return putState(request, env, path, auth.machine);
      }
      return json(405, { error: "method_not_allowed" });
    }
    return json(404, { error: "route_not_found" });
  },
};
