# Backend v2 Phase 1: State-Repo Split + Worker/D1 HTTP Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split coordination state into its own private repo and add an HTTP backend (Cloudflare Worker + D1 versioned-JSON store) behind the unchanged `agent-coord` CLI contract, implementing shakacode/agent-coordination#3 and the reorg decision.

**Architecture:** The Worker is a small versioned JSON key-value API (`/v1/state/<path>` with `If-Match` optimistic concurrency) — deliberately NOT the relational schema from docs/backend-design.md, which is the Phase 2 (#4) target when claim logic moves server-side. In Phase 1 all claim/heartbeat/status logic stays in the proven Ruby `Runner`; only the storage transport changes. A new `HttpStore` class sits beside `GitHubStore`/`LocalStore` and maps `read_json`/`write_json`/`list_json` 1:1 onto HTTP calls, so CAS semantics, exit codes, and JSON output are byte-identical to today.

**Tech Stack:** Ruby 3.4 stdlib (CLI, tests via minitest + WEBrick stub), TypeScript Cloudflare Worker (no framework), D1 (SQLite), wrangler v4, bash integration harness.

## Global Constraints

- CLI exit-code contract is frozen: 0 success, 1 usage, 2 operational, 3 CLAIM_REFUSED. Never add or change codes.
- `schema_version` stays `1`. No new JSON fields in claims/heartbeats/batches in this phase.
- CLI uses Ruby stdlib only (`net/http`, `json`, `digest`, `webrick` for tests). No new gems in the Gemfile runtime group.
- `bundle exec rubocop` must pass before every commit. All files end with a trailing newline.
- Worker code lives under `worker/`; D1 binding name is `DB`; database name is `agent-coord`; all API routes are under `/v1`.
- Bearer tokens are never committed. Token hashes are SHA-256 hex.
- API response shapes: `GET state` → `{"path":"...","data":{...},"version":N}`; errors → `{"error":"<snake_case>"}` with proper status code.
- Env vars: `AGENT_COORD_API_URL`, `AGENT_COORD_API_TOKEN` select the HTTP backend. Existing `AGENT_COORD_STATE_ROOT`, `AGENT_COORD_BACKEND`, `AGENT_COORD_REF` keep their current meaning.
- After Task 3 lands, no state files (`claims/`, `heartbeats/`, `batches/`) may ever be committed to this repo again.
- Steps marked **[OPERATOR]** require Justin (repo creation, machine env rollout, deploy secrets). Agents stop and report at those steps; they do not improvise around them.

---

### Task 1: Create and seed `agent-coordination-state`

**Files:**
- No files change in this repo. Work happens in a fresh clone of the new repo.

**Interfaces:**
- Produces: private repo `shakacode/agent-coordination-state` with README-only `main` as the default branch and a non-default `state` branch containing the current `claims/`, `heartbeats/`, `batches/` trees. Task 2 points the CLI default backend at it while the rollout keeps `AGENT_COORD_REF=state`.

- [ ] **Step 1: [OPERATOR] Create the private repo**

```bash
gh repo create shakacode/agent-coordination-state --private \
  --description "Data-only coordination state and export archive for agent-coord. Code lives in shakacode/agent-coordination."
```

Expected: `https://github.com/shakacode/agent-coordination-state`

- [ ] **Step 2: Seed it with the current state trees**

```bash
cd "$(mktemp -d)"
git clone --branch state --single-branch --depth 1 https://github.com/shakacode/agent-coordination code
git clone https://github.com/shakacode/agent-coordination-state state
cd state
printf '# agent-coordination-state\n\nData-only. Live GitHub-store state during transition; bot-authored export archive after the D1 cutover.\nCode, CLI, Worker, and dashboard live in shakacode/agent-coordination.\n' > README.md
git add README.md
git commit -m "Document state archive repository"
git push origin main
git checkout -b state
cp -R ../code/claims ../code/heartbeats ../code/batches . 2>/dev/null || true
git add claims heartbeats batches
git commit -m "Seed state from shakacode/agent-coordination state branch"
git push origin state
```

- [ ] **Step 3: Verify the seed is complete**

```bash
diff <(cd code && find claims heartbeats batches -name '*.json' | sort) \
     <(cd state && find claims heartbeats batches -name '*.json' | sort) && echo SEED_OK
```

Expected: `SEED_OK`

- [ ] **Step 4: [OPERATOR] Flip live machines**

On every machine that runs `agent-coord`, set in the shell profile:

```bash
export AGENT_COORD_BACKEND=shakacode/agent-coordination-state
export AGENT_COORD_REF=state
```

Also update the launchd/systemd heartbeat and refresh units: the heartbeat commands set `AGENT_COORD_REF=state` inline, and the refresh unit's checkout becomes a clone of the `agent-coordination-state` `state` branch. Confirm one heartbeat commit lands in the state repo's `state` branch before proceeding to Task 2.

---

### Task 2: Point the CLI default backend at the state repo

**Files:**
- Modify: `bin/agent-coord` (constant `DEFAULT_BACKEND`, line ~16)
- Modify: `test/agent_coord_test.rb` (assertions pinning the old default)
- Modify: `README.md` (backend references)

**Interfaces:**
- Consumes: Task 1's populated state repo.
- Produces: `AgentCoord::DEFAULT_BACKEND == "shakacode/agent-coordination-state"`.

- [ ] **Step 1: Update the failing assertions first**

```bash
grep -n "shakacode/agent-coordination" test/agent_coord_test.rb
```

For every match that asserts the default backend string (e.g. in `version --json` / `config --json` expectations), change the expected value to `"shakacode/agent-coordination-state"`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby test/agent_coord_test.rb`
Expected: FAIL — the changed assertions report expected `...-state`, actual `shakacode/agent-coordination`.

- [ ] **Step 3: Change the constant**

In `bin/agent-coord`:

```ruby
DEFAULT_BACKEND = "shakacode/agent-coordination-state"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby test/agent_coord_test.rb`
Expected: `0 failures, 0 errors` (the pre-existing count of runs/assertions, all green).

- [ ] **Step 5: Update README backend references**

In `README.md`, replace prose saying state lives “in this repository” with: state lives in `shakacode/agent-coordination-state`; this repo holds the CLI, Worker, dashboard, and docs.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec rubocop
git add -A && git commit -m "Point default GitHub backend at agent-coordination-state"
```

---

### Task 3: Remove state trees from the code repo

**Files:**
- Delete: `claims/`, `heartbeats/`, `batches/` directories
- Modify: `.github/workflows/ci.yml` (drop the three `paths-ignore` entries for those dirs)

**Interfaces:**
- Consumes: Task 1 Step 4 confirmation (machines flipped). **Do not start before the operator confirms.**

- [ ] **Step 1: [OPERATOR] Confirm no machine still targets this repo as backend**

Check the newest commit timestamps: `git log -1 --format=%cI -- heartbeats/` — must be older than the flip in Task 1 Step 4.

- [ ] **Step 2: Delete the state trees and CI exclusions**

```bash
git rm -r claims heartbeats batches
```

In `.github/workflows/ci.yml`, delete the three lines under `paths-ignore:` for `batches/**`, `claims/**`, `heartbeats/**` (and the `paths-ignore:` key if now empty).

- [ ] **Step 3: Verify the suite still passes**

Run: `bundle exec ruby test/agent_coord_test.rb && bundle exec rubocop`
Expected: green. (Tests use temp dirs, not the live trees; if any test referenced the live trees, point it at a fixture under `test/fixtures/state/` created by copying the referenced files before deletion.)

- [ ] **Step 4: Commit**

```bash
git commit -m "Move live state to agent-coordination-state; this repo is code-only"
```

---

### Task 4: Worker scaffold — wrangler config, migration, health route

**Files:**
- Create: `worker/wrangler.toml`
- Create: `worker/migrations/0001_state.sql`
- Create: `worker/src/index.ts`
- Create: `worker/package.json`
- Create: `worker/.gitignore`

**Interfaces:**
- Produces: `GET /v1/health` → `200 {"status":"ok"}`; D1 tables `state` and `machines`; the `Env` type `{ DB: D1Database }` used by Tasks 5–6.

- [x] **Step 1: Write the config and migration**

`worker/wrangler.toml`:

```toml
name = "agent-coord-api"
main = "src/index.ts"
compatibility_date = "2026-06-01"

[[d1_databases]]
binding = "DB"
database_name = "agent-coord"
database_id = "REPLACE_AT_DEPLOY"   # [OPERATOR] fills after `wrangler d1 create agent-coord`
```

`worker/migrations/0001_state.sql`:

```sql
CREATE TABLE IF NOT EXISTS state (
  path TEXT PRIMARY KEY,
  data TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS machines (
  machine TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);
```

`worker/package.json`:

```json
{
  "name": "agent-coord-api",
  "private": true,
  "scripts": {
    "dev": "wrangler dev --local --port 8787",
    "deploy": "wrangler deploy"
  },
  "devDependencies": {
    "wrangler": "^4.0.0",
    "typescript": "^5.5.0",
    "@cloudflare/workers-types": "^4.20260601.0"
  }
}
```

`worker/.gitignore`:

```
node_modules/
.wrangler/
```

- [x] **Step 2: Write the skeleton with only the health route**

`worker/src/index.ts`:

```ts
export interface Env {
  DB: D1Database;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/v1/health") {
      return json(200, { status: "ok" });
    }
    return json(404, { error: "not_found" });
  },
};
```

- [x] **Step 3: Verify locally**

```bash
cd worker && npm install
npx wrangler d1 migrations apply agent-coord --local
npx wrangler dev --local --port 8787 &
sleep 3
curl -s http://127.0.0.1:8787/v1/health
kill %1
```

Expected: `{"status":"ok"}`

- [x] **Step 4: Commit**

```bash
cd .. && git add worker && git commit -m "Add Worker scaffold: wrangler config, D1 migration, health route"
```

---

### Task 5: Worker bearer-token auth

**Files:**
- Modify: `worker/src/index.ts`

**Interfaces:**
- Produces: `authenticate(request, env)` returning `machine: string | null`; every non-health route returns `401 {"error":"unauthorized"}` without a valid token. Tokens verified as SHA-256 hex against `machines.token_hash` where `revoked_at IS NULL`.

- [x] **Step 1: Add the auth function and wire it in**

Add to `worker/src/index.ts` above `export default`:

```ts
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
```

Replace the `fetch` body with:

```ts
    const url = new URL(request.url);
    if (url.pathname === "/v1/health") {
      return json(200, { status: "ok" });
    }
    const machine = await authenticate(request, env);
    if (!machine) {
      return json(401, { error: "unauthorized" });
    }
    return json(404, { error: "not_found" });
```

- [x] **Step 2: Verify 401 and 200 paths**

```bash
cd worker
npx wrangler d1 execute agent-coord --local --command \
  "INSERT OR REPLACE INTO machines (machine, token_hash, created_at) VALUES ('test-machine', '$(printf %s devtoken | shasum -a 256 | cut -d" " -f1)', '2026-07-04T00:00:00Z')"
npx wrangler dev --local --port 8787 &
sleep 3
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8787/v1/state/claims/x/y/1.json
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer devtoken" http://127.0.0.1:8787/v1/state/claims/x/y/1.json
kill %1
```

Expected: `401` then `404`.

- [x] **Step 3: Commit**

```bash
cd .. && git add worker/src/index.ts && git commit -m "Add per-machine bearer-token auth to Worker"
```

---

### Task 6: Worker versioned state routes (GET / PUT / LIST)

**Files:**
- Modify: `worker/src/index.ts`
- Create: `worker/bin/smoke` (bash smoke test)

**Interfaces:**
- Produces the transport contract Task 7–8 consume:
  - `GET /v1/state/<path>` → `200 {"path","data","version"}` | `404 {"error":"not_found"}`
  - `PUT /v1/state/<path>` body `{"data":<json>}`; header `If-None-Match: *` (create) → `201` or `409 {"error":"already_exists"}`; header `If-Match: <version>` (update) → `200 {"version":N+1}` or `409 {"error":"version_conflict"}`; neither header → `400 {"error":"precondition_required"}`
  - `GET /v1/state?prefix=<claims|heartbeats|batches>` → `200 {"entries":[{"path","data","version"},...]}`
  - Path rule: `^(claims|heartbeats|batches)/[A-Za-z0-9_.:/-]+\.json$`, no `..`, no empty segment → else `400 {"error":"invalid_path"}`.

- [x] **Step 1: Add path validation and the three handlers**

Add above `export default`:

```ts
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
  let body: { data?: unknown };
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (body.data === undefined) return json(400, { error: "missing_data" });
  const data = JSON.stringify(body.data);
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
    const version = Number.parseInt(ifMatch, 10);
    if (Number.isNaN(version)) return json(400, { error: "invalid_if_match" });
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
```

Replace the trailing `return json(404, ...)` in `fetch` with:

```ts
    if (url.pathname === "/v1/state" && request.method === "GET") {
      return listState(env, url.searchParams.get("prefix") ?? "");
    }
    if (url.pathname.startsWith("/v1/state/")) {
      const path = decodeURIComponent(url.pathname.slice("/v1/state/".length));
      if (!validPath(path)) return json(400, { error: "invalid_path" });
      if (request.method === "GET") return getState(env, path);
      if (request.method === "PUT") return putState(request, env, path);
      return json(405, { error: "method_not_allowed" });
    }
    return json(404, { error: "not_found" });
```

- [x] **Step 2: Write the smoke test**

`worker/bin/smoke`:

```bash
#!/usr/bin/env bash
# Requires wrangler dev already running on :8787 with token 'devtoken' provisioned.
set -euo pipefail
BASE=http://127.0.0.1:8787
AUTH="Authorization: Bearer devtoken"
P="claims/shakacode/demo/999.json"
fail() { echo "SMOKE FAIL: $1"; exit 1; }
expect() { [ "$2" = "$3" ] || fail "$1: expected $3 got $2"; }

expect create   "$(curl -s -o /dev/null -w %{http_code} -X PUT "$BASE/v1/state/$P" -H "$AUTH" -H 'If-None-Match: *' -d '{"data":{"schema_version":1,"agent_id":"a1"}}')" 201
expect recreate "$(curl -s -o /dev/null -w %{http_code} -X PUT "$BASE/v1/state/$P" -H "$AUTH" -H 'If-None-Match: *' -d '{"data":{}}')" 409
expect get      "$(curl -s "$BASE/v1/state/$P" -H "$AUTH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')" 1
expect casok    "$(curl -s -o /dev/null -w %{http_code} -X PUT "$BASE/v1/state/$P" -H "$AUTH" -H 'If-Match: 1' -d '{"data":{"agent_id":"a2"}}')" 200
expect casstale "$(curl -s -o /dev/null -w %{http_code} -X PUT "$BASE/v1/state/$P" -H "$AUTH" -H 'If-Match: 1' -d '{"data":{"agent_id":"a3"}}')" 409
expect nohdr    "$(curl -s -o /dev/null -w %{http_code} -X PUT "$BASE/v1/state/$P" -H "$AUTH" -d '{"data":{}}')" 400
expect badpath  "$(curl -s -o /dev/null -w %{http_code} "$BASE/v1/state/etc/passwd" -H "$AUTH")" 400
expect list     "$(curl -s "$BASE/v1/state?prefix=claims" -H "$AUTH" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["entries"]) >= 1)')" True
echo SMOKE_OK
```

```bash
chmod +x worker/bin/smoke
```

- [x] **Step 3: Run it**

```bash
cd worker && npx wrangler dev --local --port 8787 & sleep 3
worker/bin/smoke
kill %1
```

Expected: `SMOKE_OK`

- [x] **Step 4: Commit**

```bash
git add worker && git commit -m "Add versioned state GET/PUT/LIST with If-Match CAS"
```

---

### Task 7: `HttpStore` reads (`read_json`, `list_json`) with stub-server tests

**Files:**
- Modify: `bin/agent-coord` (new class after `GitHubStore`)
- Create: `test/http_store_test.rb`

**Interfaces:**
- Consumes: transport contract from Task 6.
- Produces: `AgentCoord::HttpStore.new(base_url:, token:)` with `read_json(path) -> StoredJson|nil`, `list_json(prefix) -> [StoredJson]`, `verify_layout!(prefixes)`, `verify_readable!` — the same duck type as `LocalStore`/`GitHubStore`. `StoredJson#sha` carries the version as a String.

- [x] **Step 1: Write the failing test**

`test/http_store_test.rb`:

```ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "net/http"
require "webrick"

load File.expand_path("../bin/agent-coord", __dir__)

class HttpStoreStub
  attr_reader :requests

  def initialize(responses)
    @responses = responses
    @requests = []
    @server = WEBrick::HTTPServer.new(
      Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    @server.mount_proc("/") do |req, res|
      @requests << { method: req.request_method, path: req.unparsed_uri,
                     auth: req["authorization"], if_match: req["if-match"],
                     if_none_match: req["if-none-match"] }
      status, body = @responses.shift || [500, { "error" => "unexpected" }]
      res.status = status
      res.content_type = "application/json"
      res.body = JSON.generate(body)
    end
    @thread = Thread.new { @server.start }
  end

  def base_url = "http://127.0.0.1:#{@server.config[:Port]}"
  def shutdown = @server.shutdown && @thread.join
end

class HttpStoreReadTest < Minitest::Test
  def with_stub(responses)
    stub = HttpStoreStub.new(responses)
    yield AgentCoord::HttpStore.new(base_url: stub.base_url, token: "tok"), stub
  ensure
    stub.shutdown
  end

  def test_read_json_returns_stored_json_with_version_as_sha
    body = { "path" => "claims/o/r/1.json", "data" => { "agent_id" => "a1" }, "version" => 7 }
    with_stub([[200, body]]) do |store, stub|
      entry = store.read_json("claims/o/r/1.json")
      assert_equal({ "agent_id" => "a1" }, entry.data)
      assert_equal "7", entry.sha
      assert_equal "Bearer tok", stub.requests.first[:auth]
    end
  end

  def test_read_json_returns_nil_on_404
    with_stub([[404, { "error" => "not_found" }]]) do |store, _|
      assert_nil store.read_json("claims/o/r/1.json")
    end
  end

  def test_read_json_raises_operational_on_500
    with_stub([[500, { "error" => "boom" }]]) do |store, _|
      assert_raises(AgentCoord::OperationalError) { store.read_json("claims/o/r/1.json") }
    end
  end

  def test_list_json_maps_entries
    body = { "entries" => [{ "path" => "heartbeats/a1.json", "data" => { "agent_id" => "a1" }, "version" => 2 }] }
    with_stub([[200, body]]) do |store, _|
      entries = store.list_json("heartbeats")
      assert_equal 1, entries.length
      assert_equal "heartbeats/a1.json", entries.first.path
      assert_equal "2", entries.first.sha
    end
  end
end
```

- [x] **Step 2: Run to verify it fails**

Run: `bundle exec ruby test/http_store_test.rb`
Expected: FAIL with `uninitialized constant AgentCoord::HttpStore`.

- [x] **Step 3: Implement `HttpStore` reads**

In `bin/agent-coord`, add `require "net/http"` and `require "uri"` to the requires, then after the `GitHubStore` class:

```ruby
  class HttpStore
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    def initialize(base_url:, token:)
      @base = base_url.to_s.chomp("/")
      @token = token
    end

    def read_json(path)
      AgentCoord.safe_path!(path)
      response = request(Net::HTTP::Get, "/v1/state/#{path}")
      return nil if response.code == "404"
      raise OperationalError, http_error("read #{path}", response) unless response.code == "200"

      body = JSON.parse(response.body)
      StoredJson.new(path: path, data: body.fetch("data"), sha: body.fetch("version").to_s)
    end

    def list_json(prefix)
      AgentCoord.safe_path!(prefix)
      response = request(Net::HTTP::Get, "/v1/state?prefix=#{prefix}")
      raise OperationalError, http_error("list #{prefix}", response) unless response.code == "200"

      JSON.parse(response.body).fetch("entries").map do |entry|
        StoredJson.new(path: entry.fetch("path"), data: entry.fetch("data"),
                       sha: entry.fetch("version").to_s)
      end
    end

    def verify_readable!
      response = request(Net::HTTP::Get, "/v1/state?prefix=claims")
      raise OperationalError, http_error("verify readable", response) unless response.code == "200"
    end

    def verify_layout!(_prefixes)
      response = request(Net::HTTP::Get, "/v1/health")
      raise OperationalError, http_error("health", response) unless response.code == "200"
    end

    private

    def request(klass, request_path, body: nil, headers: {})
      uri = URI.parse("#{@base}#{request_path}")
      http_request = klass.new(uri)
      http_request["Authorization"] = "Bearer #{@token}"
      headers.each { |name, value| http_request[name] = value }
      if body
        http_request["Content-Type"] = "application/json"
        http_request.body = JSON.generate(body)
      end
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(http_request)
      end
    rescue SystemCallError, Timeout::Error, IOError => e
      raise OperationalError, "http backend unreachable: #{e.message}"
    end

    def http_error(action, response)
      detail = begin
        JSON.parse(response.body).fetch("error", response.body)
      rescue JSON::ParserError
        response.body.to_s[0, 200]
      end
      "http backend #{action} failed: #{response.code} #{detail}"
    end
  end
```

- [x] **Step 4: Run to verify it passes**

Run: `bundle exec ruby test/http_store_test.rb`
Expected: `4 runs ... 0 failures, 0 errors`.

- [x] **Step 5: Lint and commit**

```bash
bundle exec rubocop && git add -A && git commit -m "Add HttpStore reads with stub-server tests"
```

---

### Task 8: `HttpStore` writes with CAS → `Conflict` mapping

**Files:**
- Modify: `bin/agent-coord` (`HttpStore#write_json`)
- Modify: `test/http_store_test.rb`

**Interfaces:**
- Produces: `write_json(path, data, message:, sha: nil, create: false)` — 201/200 → success; 409 → `Conflict` with the exact strings the other stores use: `"state already exists at #{path}"` (create) / `"state changed at #{path}"` (update). This preserves claim/heartbeat/release behavior in `Runner` unchanged.

- [x] **Step 1: Write the failing tests** (append to `HttpStoreReadTest`’s file as a new class)

```ruby
class HttpStoreWriteTest < Minitest::Test
  def with_stub(responses, &block)
    HttpStoreReadTest.instance_method(:with_stub).bind_call(self, responses, &block)
  end

  def test_create_sends_if_none_match_and_succeeds_on_201
    with_stub([[201, { "path" => "claims/o/r/1.json", "version" => 1 }]]) do |store, stub|
      store.write_json("claims/o/r/1.json", { "a" => 1 }, message: "m", create: true)
      assert_equal "*", stub.requests.first[:if_none_match]
    end
  end

  def test_create_conflict_raises_already_exists
    with_stub([[409, { "error" => "already_exists" }]]) do |store, _|
      error = assert_raises(AgentCoord::Conflict) do
        store.write_json("claims/o/r/1.json", {}, message: "m", create: true)
      end
      assert_equal "state already exists at claims/o/r/1.json", error.message
    end
  end

  def test_update_sends_if_match_and_conflict_raises_state_changed
    with_stub([[409, { "error" => "version_conflict" }]]) do |store, stub|
      error = assert_raises(AgentCoord::Conflict) do
        store.write_json("claims/o/r/1.json", {}, message: "m", sha: "7")
      end
      assert_equal "7", stub.requests.first[:if_match]
      assert_equal "state changed at claims/o/r/1.json", error.message
    end
  end

  def test_write_without_sha_or_create_is_usage_error
    with_stub([]) do |store, _|
      assert_raises(AgentCoord::Error) do
        store.write_json("claims/o/r/1.json", {}, message: "m")
      end
    end
  end
end
```

- [x] **Step 2: Run to verify failure**

Run: `bundle exec ruby test/http_store_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'write_json'`.

- [x] **Step 3: Implement**

Inside `HttpStore` (public section, after `list_json`):

```ruby
    # message is accepted for interface parity; the HTTP backend has no commit messages.
    def write_json(path, data, message:, sha: nil, create: false) # rubocop:disable Lint/UnusedMethodArgument
      AgentCoord.safe_path!(path)
      raise Error, "write_json requires sha or create" if sha.nil? && !create

      headers = sha ? { "If-Match" => sha } : { "If-None-Match" => "*" }
      response = request(Net::HTTP::Put, "/v1/state/#{path}", body: { "data" => data }, headers: headers)
      case response.code
      when "200", "201" then nil
      when "409"
        raise Conflict, (create ? "state already exists at #{path}" : "state changed at #{path}")
      else
        raise OperationalError, http_error("write #{path}", response)
      end
    end
```

- [x] **Step 4: Run full suite**

Run: `bundle exec ruby test/http_store_test.rb && bundle exec ruby test/agent_coord_test.rb`
Expected: all green.

- [x] **Step 5: Lint and commit**

```bash
bundle exec rubocop && git add -A && git commit -m "Add HttpStore CAS writes mapped to Conflict semantics"
```

---

### Task 9: Backend selection — env plumbing, precedence, both-set warning

**Files:**
- Modify: `bin/agent-coord` (`parse_options`, `build_store`)
- Modify: `test/http_store_test.rb` (new class `HttpBackendSelectionTest`)

**Interfaces:**
- Produces the selection rule every later task and all docs rely on:
  1. `--state-root` flag → `LocalStore`
  2. `--api-url` flag or `AGENT_COORD_API_URL` env → `HttpStore` (requires `AGENT_COORD_API_TOKEN`, else `OperationalError` exit 2)
  3. `AGENT_COORD_STATE_ROOT` env → `LocalStore`
  4. otherwise → `GitHubStore`
  - When both `AGENT_COORD_API_URL` and `AGENT_COORD_STATE_ROOT` env vars are set, warn once on stderr: `warning: AGENT_COORD_API_URL and AGENT_COORD_STATE_ROOT are both set; using the HTTP backend. Pass --state-root to force local.`

- [x] **Step 1: Write the failing test**

```ruby
class HttpBackendSelectionTest < Minitest::Test
  def run_cli(args, env)
    stdout = StringIO.new
    stderr = StringIO.new
    code = begin
      AgentCoord::Runner.new(args, stdout: stdout, stderr: stderr).run
    rescue AgentCoord::Error => e
      stderr.puts e.message
      e.exit_code
    end
    [code, stdout.string, stderr.string]
  end

  def test_status_uses_http_backend_when_api_env_set
    stub = HttpStoreStub.new([
      [200, { "entries" => [] }], [200, { "entries" => [] }], [200, { "entries" => [] }]
    ])
    env = { "AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok" }
    with_env(env) do
      code, out, = run_cli(["status"], env)
      assert_equal 0, code
      assert_includes out, "claims"
    end
    assert_equal 3, stub.requests.length
  ensure
    stub.shutdown
  end

  def test_missing_token_is_operational_error
    with_env("AGENT_COORD_API_URL" => "http://127.0.0.1:9", "AGENT_COORD_API_TOKEN" => nil) do
      code, _, err = run_cli(["status"], {})
      assert_equal 2, code
      assert_includes err, "AGENT_COORD_API_TOKEN"
    end
  end

  def test_both_env_vars_warns_and_uses_http
    stub = HttpStoreStub.new([[200, { "entries" => [] }], [200, { "entries" => [] }], [200, { "entries" => [] }]])
    with_env("AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok",
             "AGENT_COORD_STATE_ROOT" => "/tmp/nonexistent-root") do
      code, _, err = run_cli(["status"], {})
      assert_equal 0, code
      assert_includes err, "both set"
    end
  ensure
    stub.shutdown
  end

  private

  def with_env(pairs)
    saved = pairs.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
```

Note: `Runner.new` currently accepts `stdout:`/`stderr:` keywords (`stderr` is stored but unused for warnings). The warning in Step 3 writes to `@stderr`.

- [x] **Step 2: Run to verify failure**

Run: `bundle exec ruby test/http_store_test.rb`
Expected: FAIL — status hits the GitHub/local path instead of the stub (first test), no token error (second), no warning (third).

- [x] **Step 3: Implement selection**

In `parse_options`, change the initial options hash: `state_root: nil, api_url: nil` (drop the direct env fetch for `state_root`), and add the flag:

```ruby
        opts.on("--api-url URL", "use the HTTP backend at URL") { |value| options[:api_url] = value }
```

After `parser.parse!(argv)` and the unexpected-arguments check, add:

```ruby
      resolve_backend_env(options)
```

Add the private method:

```ruby
    def resolve_backend_env(options)
      return if options[:state_root] # explicit flag wins

      env_api = ENV.fetch("AGENT_COORD_API_URL", nil)
      env_root = ENV.fetch("AGENT_COORD_STATE_ROOT", nil)
      options[:api_url] ||= env_api
      if options[:api_url]
        if env_root && !env_root.empty?
          @stderr.puts "warning: AGENT_COORD_API_URL and AGENT_COORD_STATE_ROOT are both set; " \
                       "using the HTTP backend. Pass --state-root to force local."
        end
        return
      end
      options[:state_root] = env_root
    end
```

In `build_store`:

```ruby
    def build_store(options)
      return LocalStore.new(options.fetch(:state_root)) if options[:state_root]

      if options[:api_url]
        token = ENV.fetch("AGENT_COORD_API_TOKEN", nil)
        if token.to_s.empty?
          raise OperationalError, "AGENT_COORD_API_TOKEN is required when using the HTTP backend"
        end
        return HttpStore.new(base_url: options[:api_url], token: token)
      end

      GitHubStore.new(backend: options.fetch(:backend), ref: options.fetch(:ref))
    end
```

In `render_status` and `doctor`, guard the mirror default so HTTP wins:

```ruby
      status_options[:state_root] ||= default_status_state_root unless status_options[:api_url]
```

(and the equivalent line in `doctor` for `doctor_options`).

- [x] **Step 4: Run the full suite**

Run: `bundle exec ruby test/http_store_test.rb && bundle exec ruby test/agent_coord_test.rb`
Expected: all green. If an existing test set `AGENT_COORD_STATE_ROOT` via ENV and relied on the old fetch location, it still passes — the env fallback moved but kept identical effect.

- [x] **Step 5: Lint and commit**

```bash
bundle exec rubocop && git add -A && git commit -m "Add HTTP backend selection with precedence and both-set warning"
```

---

### Task 10: `doctor` support for the HTTP backend

**Files:**
- Modify: `bin/agent-coord` (`doctor`)
- Modify: `test/http_store_test.rb`

**Interfaces:**
- Produces: `agent-coord doctor` with the HTTP backend reports `backend: http` and `backend_url`, checks `/v1/health` and a claims list; `--deep` lists all three prefixes.

- [x] **Step 1: Write the failing test**

```ruby
class HttpDoctorTest < Minitest::Test
  def test_doctor_reports_http_backend
    # Order matters: the http branch calls verify_readable! (claims list) first;
    # the existing outer store.verify_layout!(JSON_PREFIXES) then hits /v1/health.
    stub = HttpStoreStub.new([
      [200, { "entries" => [] }],           # verify_readable! -> list claims
      [200, { "status" => "ok" }]           # outer verify_layout! -> /v1/health
    ])
    HttpBackendSelectionTest.instance_method(:with_env).bind_call(
      self, "AGENT_COORD_API_URL" => stub.base_url, "AGENT_COORD_API_TOKEN" => "tok"
    ) do
      stdout = StringIO.new
      code = AgentCoord::Runner.new(["doctor"], stdout: stdout, stderr: StringIO.new).run
      assert_equal 0, code
      assert_includes stdout.string, "backend: http"
      assert_includes stdout.string, stub.base_url
    end
  ensure
    stub.shutdown
  end
end
```

- [x] **Step 2: Run to verify failure**

Run: `bundle exec ruby test/http_store_test.rb`
Expected: FAIL — doctor reports `backend: github` and tries `gh auth status`.

- [x] **Step 3: Implement**

In `doctor`, before the current `backend_kind` logic:

```ruby
      doctor_options[:state_root] ||= default_status_state_root unless doctor_options[:api_url]
      backend_kind =
        if doctor_options[:api_url] && !doctor_options[:state_root] then "http"
        elsif doctor_options[:state_root] then "local"
        else "github"
        end
```

Add an `http` branch to the begin block. **Keep the two existing branches (local and github) exactly as they are — do not delete or reorder their contents.** Only insert the new first branch, so the structure becomes:

```ruby
        if backend_kind == "http"
          store = build_store(doctor_options)
          store.verify_readable!                # GET /v1/state?prefix=claims
        elsif doctor_options[:state_root]
          # existing local branch, unchanged: LocalStore.new + verify_root!
        else
          # existing github branch, unchanged: gh auth/repo checks + verify_readable!
        end
```

The existing `store.verify_layout!(JSON_PREFIXES)` call after the branch stays where it is — for the HTTP backend it performs the `/v1/health` check (see `HttpStore#verify_layout!` from Task 7).

Extend the payload and text output with `"backend_url" => doctor_options[:api_url]` and a `backend_url:` line when backend is http.

- [x] **Step 4: Run, lint, commit**

Run: `bundle exec ruby test/http_store_test.rb && bundle exec ruby test/agent_coord_test.rb && bundle exec rubocop`
Expected: green.

```bash
git add -A && git commit -m "Teach doctor the HTTP backend"
```

---

### Task 11: End-to-end parity harness (`wrangler dev` + real CLI)

**Files:**
- Create: `bin/test-http-integration`
- Create: `test/http_backend_integration_test.rb`

**Interfaces:**
- Consumes: everything above.
- Produces: one command that proves the #3 acceptance criteria: contention refusal (exit 3), dead-holder takeover, two-concurrent-claims single winner, heartbeat/status/release parity.

- [x] **Step 1: Write the harness**

`bin/test-http-integration`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-coord-wrangler.XXXXXX")
WRANGLER_PID=""

process_alive() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null
}

collect_tree() {
  local pid="$1"
  local child
  process_alive "$pid" || return 0
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
      collect_tree "$child"
    done
  fi
  printf '%s\n' "$pid"
}

signal_pids() {
  local signal="$1"
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill "$signal" "$pid" 2>/dev/null || true
  done
}

wait_for_tree_exit() {
  local deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -z "$(collect_tree "$WRANGLER_PID")" ] && return 0
    sleep 0.2
  done
  return 1
}

cleanup() {
  local status=$?
  if [ -n "$WRANGLER_PID" ]; then
    signal_pids -TERM <<<"$(collect_tree "$WRANGLER_PID")"
    if ! wait_for_tree_exit; then
      signal_pids -KILL <<<"$(collect_tree "$WRANGLER_PID")"
    fi
    wait "$WRANGLER_PID" 2>/dev/null || true
  fi
  ruby -rfileutils -e 'FileUtils.rm_rf(ARGV.fetch(0))' "$TMP_ROOT"
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export XDG_CONFIG_HOME="$TMP_ROOT/config"
export XDG_CACHE_HOME="$TMP_ROOT/cache"
export WRANGLER_LOG_PATH="$TMP_ROOT/logs"
export WRANGLER_OUTPUT_LOG="$TMP_ROOT/wrangler-integration.log"
export WRANGLER_SEND_METRICS=false
export WRANGLER_SEND_ERROR_REPORTS=false
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$WRANGLER_LOG_PATH"
TOKEN=$(ruby -rsecurerandom -e 'print SecureRandom.hex(24)')
HASH=$(ruby -rdigest -e 'print Digest::SHA256.hexdigest(ARGV.fetch(0))' "$TOKEN")

health_ready() {
  ruby -rnet/http -ruri -e '
    uri = URI("http://127.0.0.1:8787/v1/health")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
      http.get(uri.request_uri)
    end
    exit(response.is_a?(Net::HTTPSuccess) ? 0 : 1)
  ' >/dev/null 2>&1
}

(cd worker && npx wrangler d1 migrations apply agent-coord --local >/dev/null)
(cd worker && npx wrangler d1 execute agent-coord --local --command \
  "INSERT OR REPLACE INTO machines (machine, token_hash, created_at) VALUES ('integration', '${HASH}', '2026-07-04T00:00:00Z')" >/dev/null)
(cd worker && npx wrangler dev --local --port 8787 >"$WRANGLER_OUTPUT_LOG" 2>&1) &
WRANGLER_PID=$!
for _ in $(seq 1 60); do
  health_ready && break
  sleep 0.5
done
health_ready || { echo "wrangler dev never became healthy"; cat "$WRANGLER_OUTPUT_LOG"; exit 1; }
AGENT_COORD_API_URL=http://127.0.0.1:8787 AGENT_COORD_API_TOKEN="$TOKEN" \
  bundle exec ruby test/http_backend_integration_test.rb
echo INTEGRATION_OK
```

```bash
chmod +x bin/test-http-integration
```

- [x] **Step 2: Write the integration test**

`test/http_backend_integration_test.rb`:

```ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

CLI = File.expand_path("../bin/agent-coord", __dir__)
REPO = "shakacode/integration-#{Process.pid}"

def cli(*args)
  stdout, stderr, status = Open3.capture3("ruby", CLI, *args)
  [status.exitstatus, stdout, stderr]
end

class HttpBackendIntegrationTest < Minitest::Test
  def test_full_claim_lifecycle_and_contention
    target = "100"
    code, out, err = cli("claim", "--agent-id", "w1", "--repo", REPO, "--target", target)
    assert_equal 0, code, "first claim failed: #{err}"
    assert_includes out, "claimed"

    # w1 heartbeats live -> w2 must be refused with exit 3
    code, = cli("heartbeat", "--agent-id", "w1", "--repo", REPO, "--target", target)
    assert_equal 0, code
    code, _, err = cli("claim", "--agent-id", "w2", "--repo", REPO, "--target", target)
    assert_equal 3, code
    assert_includes err, "CLAIM_REFUSED"

    # dead-holder takeover: a 1-second-TTL heartbeat is "dead" after 4 x ttl = 4s
    # (liveness rule: dead when now >= updated_at + 4*ttl). The claim itself is
    # still unexpired, so this exercises the heartbeat-dead takeover path, not
    # the claim-expiry fallback.
    code, = cli("heartbeat", "--agent-id", "w1", "--repo", REPO, "--target", target, "--ttl", "1")
    assert_equal 0, code
    sleep 5
    code, _, err = cli("claim", "--agent-id", "w2", "--repo", REPO, "--target", target)
    assert_equal 0, code, "dead-holder takeover failed: #{err}"

    # release parity check on the new holder
    code, = cli("release", "--agent-id", "w2", "--repo", REPO, "--target", target)
    assert_equal 0, code
    code, = cli("claim", "--agent-id", "w2", "--repo", REPO, "--target", target)
    assert_equal 0, code

    code, out, = cli("status", "--repo", REPO, "--target", target, "--json")
    assert_equal 0, code
    payload = JSON.parse(out)
    assert_equal "w2", payload.fetch("claims").first.fetch("agent_id")
  end

  def test_concurrent_claims_have_exactly_one_winner
    target = "200"
    results = Array.new(4) { nil }
    threads = results.each_index.map do |i|
      Thread.new { results[i] = cli("claim", "--agent-id", "racer#{i}", "--repo", REPO, "--target", target).first }
    end
    threads.each(&:join)
    winners = results.count(0)
    assert_equal 1, winners, "expected exactly one winner, got exits #{results.inspect}"
    assert results.all? { |code| [0, 2, 3].include?(code) }, "unexpected exit in #{results.inspect}"
  end
end
```

- [x] **Step 3: Run it**

Run: `bin/test-http-integration`
Expected: both tests pass, then `INTEGRATION_OK`.

- [x] **Step 4: Commit**

```bash
bundle exec rubocop && git add -A && git commit -m "Add end-to-end HTTP backend parity harness"
```

---

### Task 12: CI job for the Worker + integration suite

**Files:**
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `bin/test-http-integration`.
- Produces: a `worker-integration` job on every PR.

- [x] **Step 1: Add the job**

Append to `.github/workflows/ci.yml` under `jobs:` (match the checkout/Ruby-setup steps of the existing `test` job verbatim, then add Node):

```yaml
  worker-integration:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false
      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: 22
      - name: Install worker deps
        run: cd worker && npm install
      - name: Run HTTP backend integration suite
        run: bin/test-http-integration
```

(If the existing jobs pin `ruby/setup-ruby` / `setup-node` to SHAs, copy those exact pins instead of the tags above.)

- [x] **Step 2: Verify locally, then push and watch CI**

Run: `bin/test-http-integration`
Expected: `INTEGRATION_OK`.

```bash
git add .github/workflows/ci.yml && git commit -m "Run Worker integration suite in CI"
git push -u origin <branch>
gh pr checks --watch
```

Expected: all jobs green including `worker-integration`.

---

### Task 13: Deploy runbook + token provisioning script

**Files:**
- Create: `worker/bin/provision-token`
- Modify: `README.md` (new “HTTP backend” section)

**Interfaces:**
- Produces: deployed Worker URL, one provisioned token per machine.

- [x] **Step 1: Write the provisioning script**

`worker/bin/provision-token`:

```bash
#!/usr/bin/env bash
# Usage: worker/bin/provision-token <machine-name> [--local]
# Prints a fresh token once; stores only its SHA-256 hash in D1.
set -euo pipefail

usage() {
  echo "usage: worker/bin/provision-token <machine-name> [--local]" >&2
  exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

MACHINE="$1"
case "$MACHINE" in
  --*) usage ;;
esac

SCOPE="${2:---remote}"

if [[ ! "$MACHINE" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "machine name may contain only letters, numbers, dots, underscores, colons, and hyphens" >&2
  exit 1
fi

case "$SCOPE" in
  --remote) ;;
  --local) ;;
  *) usage ;;
esac

OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
NPX_BIN="${NPX_BIN:-npx}"

TOKEN=$("$OPENSSL_BIN" rand -hex 24)
HASH=$(printf %s "$TOKEN" | "$OPENSSL_BIN" dgst -sha256 -r | cut -d' ' -f1)
SQL="INSERT INTO machines (machine, token_hash, created_at) VALUES ('${MACHINE}', '${HASH}', strftime('%Y-%m-%dT%H:%M:%SZ','now'))"

cd "$(dirname "$0")/.."
COMMAND=("$NPX_BIN" wrangler d1 execute agent-coord)
COMMAND+=("$SCOPE")
COMMAND+=(--command "$SQL")
if ! "${COMMAND[@]}"; then
  echo "wrangler d1 execute failed while provisioning ${MACHINE}; see wrangler output above" >&2
  echo "If this was a duplicate machine or token constraint, delete or update the existing D1 machines row before re-provisioning" >&2
  exit 1
fi

echo "machine:  ${MACHINE}"
echo "token:    ${TOKEN}"
echo "Set on that machine:"
echo "  export AGENT_COORD_API_URL=<worker-url>"
echo "  export AGENT_COORD_API_TOKEN=${TOKEN}"
```

```bash
chmod +x worker/bin/provision-token
```

- [x] **Step 2: [OPERATOR] Deploy**

```bash
cd worker
npx wrangler login                       # justin@shakacode.com account
npx wrangler d1 create agent-coord      # paste database_id into wrangler.toml
npx wrangler d1 migrations apply agent-coord --remote
npx wrangler deploy                      # note the workers.dev URL
worker/bin/provision-token <machine-name>   # once per machine
curl -s <worker-url>/v1/health
```

Expected: `{"status":"ok"}`

Completed 2026-07-07 UTC: D1 database `agent-coord`
(`0d75340b-8414-405a-9beb-97a857b80d2c`) is bound to Worker
`agent-coord-api`, migrations were applied, and the deployed endpoint
`https://agent-coord-api.justin-fed.workers.dev/v1/health` returned
`{"status":"ok"}`. M5 was provisioned with a private token; no bearer tokens are
committed.

- [x] **Step 3: Document**

Add to `README.md` a section “HTTP backend” containing: the selection precedence from Task 9 verbatim, the two env vars, `worker/bin/provision-token` usage, and the rollback line: “unset `AGENT_COORD_API_URL` to fall back to the GitHub store.”

- [x] **Step 4: Commit**

```bash
bundle exec rubocop && git add -A && git commit -m "Add token provisioning script and HTTP backend docs"
```

---

### Task 14: [OPERATOR] Pilot cutover checklist

No file changes. Execute the grill-decided cutover:

- [x] 1. On M5 only, set `AGENT_COORD_API_URL` + `AGENT_COORD_API_TOKEN` in a temporary shell. Do not persist them to shell profiles, launchd units, or shared config yet.
- [x] 2. Run `agent-coord doctor --json` on M5 — expect `backend: http`, `status: ok`.
- [x] 3. Create or grant access to `shakacode/agent-coord-sim-alpha` and `shakacode/agent-coord-sim-beta`, seed them from `sim/template/`, and run one seeded sim batch end-to-end on HTTP.
- [x] 4. Drain in-flight batches on `shakacode/react_on_rails` (no live claims for that repo in `agent-coord status`), then run one `react_on_rails` batch end-to-end on HTTP.
- [x] 5. On success, persist the M5 env vars. Rollback at any point before persistence: unset the two env vars or close the shell.

Pilot evidence recorded 2026-07-07 UTC: both sim repos scored `SCORE 3/3`,
`shakacode/react_on_rails` PR
[`#4514`](https://github.com/shakacode/react_on_rails/pull/4514) merged through
the merge queue at `765e74b4be5717f876cc8acc6a29766530f9430b`, and a fresh M5
login shell resolved `agent-coord` to the canonical public checkout with
`doctor --json` reporting `backend: http` and `status: ok`. Additional machine
or repo flips remain explicit follow-up rollout decisions.

---

## Roadmap: subsequent plans (separate documents, in order)

0. **Parallel track — [`2026-07-04-batch-simulation-harness.md`](2026-07-04-batch-simulation-harness.md):** deterministic scripted-worker protocol tests (CI, no LLM, LocalStore today / HTTP backend once this plan lands) plus two seeded GitHub sim repos where real Codex and Claude sessions process issue batches and a scorecard verifies claims/PRs/CI. Layer 1 can start immediately; Layer 2's live scenarios become the acceptance demo for this phase's cutover.
1. **Phase 2 — `2026-XX-XX-backend-v2-phase2.md` (#4):** relational schema migration (claims/agent_status/machine_liveness/lanes/events tables per docs/backend-design.md), server-side claim ops with single-statement CAS (generation fencing, instance ids, `--supersede`), sticky terminal status, `cancel` verb, `register-batch`, thread handles + phases, **`host` attribution (codex | claude-code) and a `handoff` release mode with resume notes** (single-PR machine/editor switching), lifecycle-hook heartbeat transport, sidecar split, bot-authored nightly export to agent-coordination-state. Supersedes the Phase 1 KV routes for claims/heartbeats (the `/v1/state` KV remains for batches passthrough until `register-batch` lands).
2. **Phase 3 — dashboard merge + API mode (dashboard#9):** subtree-merge `agent-coordination-dashboard` into `dashboard/`, transfer its issue, archive the old repo; reader swap to the Worker API; polling; thread handles + host/machine columns; wedged detection; registration-first start flow; Worker-served read view behind Cloudflare Access.
3. **Phase 4 — agent-workflows text (#63, #64, #76, pr-lane):** coordination contract doc additions, push-phase ownership verification, thread-handle goal-prompt line, Lane Card, address-review exclusion, and the **pr-lane skill** (coordinated single-PR flow for direct-prompt work: claim → CI/review process → PR↔dashboard mapping → explicit handoff/release for machine or editor switches). Blocked by Phase 2 fields.
4. **Phase 5 — launcher + reservations (#5, #6):** `launch_requested` polling daemon spawning `codex exec`/`claude -p` in worktrees; capacity reservations closing the triage race.
