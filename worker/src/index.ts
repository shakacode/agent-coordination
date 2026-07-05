export interface Env {
  DB: D1Database;
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

async function authenticate(request: Request, env: Env): Promise<string | null> {
  const header = request.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer (.+)$/);
  if (!match) return null;
  const hash = await sha256Hex(match[1]);
  const row = await env.DB.prepare(
    "SELECT machine FROM machines WHERE token_hash = ? AND revoked_at IS NULL",
  ).bind(hash).first<{ machine: string }>();
  return row?.machine ?? null;
}

const STATE_PATH = /^(claims|heartbeats|batches)\/[A-Za-z0-9_.:/-]+\.json$/;

function validPath(path: string): boolean {
  return STATE_PATH.test(path) && !path.includes("..") && !path.includes("//");
}

async function getState(env: Env, path: string): Promise<Response> {
  const row = await env.DB.prepare("SELECT data, version FROM state WHERE path = ?")
    .bind(path).first<{ data: string; version: number }>();
  if (!row) return json(404, { error: "not_found" });
  return json(200, { path, data: JSON.parse(row.data), version: row.version });
}

async function putState(request: Request, env: Env, path: string): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return json(400, { error: "missing_data" });
  }
  const payload = body as { data?: unknown };
  if (payload.data === undefined) return json(400, { error: "missing_data" });
  const data = JSON.stringify(payload.data);
  const now = new Date().toISOString();
  const ifMatch = request.headers.get("if-match");
  const ifNoneMatch = request.headers.get("if-none-match");

  if (ifNoneMatch === "*") {
    const result = await env.DB.prepare(
      "INSERT INTO state (path, data, version, updated_at) VALUES (?, ?, 1, ?) ON CONFLICT (path) DO NOTHING",
    ).bind(path, data, now).run();
    if (result.meta.changes === 0) return json(409, { error: "already_exists" });
    return json(201, { path, version: 1 });
  }
  if (ifMatch) {
    if (!/^\d+$/.test(ifMatch)) return json(400, { error: "invalid_if_match" });
    const version = Number.parseInt(ifMatch, 10);
    const result = await env.DB.prepare(
      "UPDATE state SET data = ?, version = version + 1, updated_at = ? WHERE path = ? AND version = ?",
    ).bind(data, now, path, version).run();
    if (result.meta.changes === 0) return json(409, { error: "version_conflict" });
    return json(200, { path, version: version + 1 });
  }
  return json(400, { error: "precondition_required" });
}

async function listState(env: Env, prefix: string): Promise<Response> {
  if (!["claims", "heartbeats", "batches"].includes(prefix)) {
    return json(400, { error: "invalid_prefix" });
  }
  const rows = await env.DB.prepare(
    "SELECT path, data, version FROM state WHERE path LIKE ? ORDER BY path",
  ).bind(`${prefix}/%`).all<{ path: string; data: string; version: number }>();
  const entries = (rows.results ?? []).map((r) => ({
    path: r.path,
    data: JSON.parse(r.data),
    version: r.version,
  }));
  return json(200, { entries });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/v1/health") {
      return json(200, { status: "ok" });
    }
    const machine = await authenticate(request, env);
    if (!machine) {
      return json(401, { error: "unauthorized" });
    }
    if (url.pathname === "/v1/state" && request.method === "GET") {
      return listState(env, url.searchParams.get("prefix") ?? "");
    }
    if (url.pathname.startsWith("/v1/state/")) {
      let path: string;
      try {
        path = decodeURIComponent(url.pathname.slice("/v1/state/".length));
      } catch {
        return json(400, { error: "invalid_path" });
      }
      if (!validPath(path)) return json(400, { error: "invalid_path" });
      if (request.method === "GET") return getState(env, path);
      if (request.method === "PUT") return putState(request, env, path);
      return json(405, { error: "method_not_allowed" });
    }
    return json(404, { error: "not_found" });
  },
};
