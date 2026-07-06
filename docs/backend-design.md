# Coordination Backend v2 Design

Date: 2026-07-04
Status: proposed (implements #3, #4, #6; decisions from the 2026-07-03 planning grill)

## Problem

The current backend stores claims, heartbeats, and batches as JSON files committed
to this repository through the GitHub Contents API. That design forces coarse
liveness (300s heartbeats, 15-minute TTL, stale zone to 75 minutes), exposes every
write to API rate limits, makes the dashboard read a locally refreshed checkout of
already-stale data, and mints every heartbeat as a commit authored by the
operator's account — inflating their GitHub contribution graph by hundreds of
commits per active day. A 2026-07-02 concurrency review additionally proved four
protocol failure modes (unfenced takeover, same-agent-id double starts, sidecar
status overwrites, unobservable cancellation) tracked in #4.

## Requirements

Functional:

- Claims with compare-and-swap acquire/renew/release, generation fencing,
  per-session instance identity, and explicit supersede (#4).
- Agent status (with phase and thread handle) split from machine liveness (#4).
- Batch registration before launch; first-class cancellation observable in status.
- Append-only events (phase transitions, stop requests).
- Capacity reservations (#6).
- Status reads in the existing three scopes (all / target / batch) with unchanged
  CLI exit codes and JSON shapes.

Non-functional (measured against current fleet):

- Load: ~10 agents × 1 heartbeat/min ≈ 14k writes/day; dashboard polling at
  1 request/5s ≈ 17k reads/day. Tiny by any hosted-database standard.
- Write latency: sub-second from bash/curl on any machine (Codex CLI, Claude Code,
  launchd sidecar, lifecycle hooks).
- Liveness resolution: minutes, not hours — 60s heartbeat cadence, 2–5 min TTL.
- Operator surface: one person; near-zero maintenance; no servers to patch.
- Cost target: ~$0 at this scale.
- Access: read-only dashboard reachable from any machine or phone.
- No commits attributed to a human account for routine state changes.
- Rollback: the GitHub store remains selectable via env vars.

## Options considered

| Dimension | Cloudflare Worker + D1 | Rails API app | Supabase (PostgREST) |
| --- | --- | --- | --- |
| Ops surface | None (managed edge; `wrangler deploy`) | Real: deploys, Postgres, patching, monitoring (Control Plane / cpflow) | Low, but a second surface for the dashboard is still needed |
| Cost at this load | $0 (free tier: 100k Worker req/day, 100k D1 writes/day vs ~14k needed) | ~$20–40/mo always-on + DB | $0 free tier or $25/mo Pro |
| Availability risk | None specific | Deploy/dyno health is yours to own | Free tier pauses projects after ~7 days of no API traffic — a paused coordination plane after a vacation is a real failure mode; Pro removes it |
| CAS / transactions | Single-statement conditional writes (see Concurrency); `db.batch()` atomic; no interactive transactions (acceptable — see below) | Full ActiveRecord transactions, row locks | Full Postgres; CAS logic must live in SQL functions exposed via `/rpc` |
| Auth (per-machine tokens) | ~10 lines in the Worker; token table | Trivial (has_secure_token etc.) | Awkward: service keys are all-or-nothing; per-machine attribution needs custom JWT claims or RLS work |
| Dashboard hosting | Same Worker serves the read view behind Cloudflare Access (grill decision) | Rails serves it; org SSO possible | Not included; still need Pages/Worker/local app |
| Realtime push | Poll (5s poll of a tiny endpoint is fine at this scale) | ActionCable | Built-in realtime subscriptions — the one genuinely superior feature |
| Team familiarity | Low (small TS surface, ~300 lines) | High (ShakaCode is a Rails shop) | Medium (gbrain already targets Supabase) |
| Time to first value | Hours | Days (app + pipeline + hosting) | Hours for DB; more for RPC functions + dashboard + tokens |
| Exit cost | Re-implement ~10 endpoints behind the same CLI contract; schema is plain SQLite | Same contract seam applies | Same |
| Launcher-queue fit (#5) | Poll `launch_requested` rows; Worker cron for sweeps | Background jobs built in | Poll or realtime |

Also considered briefly: **Turso** (libSQL — equivalent to D1 without the
integrated compute/hosting), **Neon** (serverless Postgres — still needs an API
layer in front, which reintroduces the Worker or an app), and **keeping GitHub
with tuning** (rejected in #3: commit-per-heartbeat is structural).

## Decision

**Cloudflare Worker + D1**, as already scoped in #3. See
[ADR 0001](adr/0001-worker-d1-backend.md) for the full rationale. The short form:

- The coordination plane must be *more* reliable and *lower-maintenance* than the
  work it coordinates. A managed edge function with an embedded SQLite database is
  the smallest possible always-on surface; a Rails app is the largest.
- One deployable covers all three needs — API, read-only dashboard, and access
  control (Cloudflare Access) — where Supabase covers only the database and Rails
  makes all three yours to operate.
- The workload (14k writes/day, 5-table schema, single-row CAS) does not use
  anything Postgres or Rails would add.
- The CLI contract is the seam: `HttpStore` speaks plain HTTP, so migrating to a
  Rails API or Supabase later means re-implementing ~10 endpoints, not touching
  any skill, workflow, or consumer repo.

Graduation criteria (revisit, do not preempt): move to a **Rails app** if this
becomes a multi-user product — several human users, write-heavy UI workflows, org
SSO, or product-grade dashboard requirements. Adopt **Supabase/Postgres** if
realtime push becomes a must-have and polling demonstrably fails, or if the
schema outgrows single-statement CAS semantics.

Named graduation path (2026-07-04): the intended multi-user product is a
**ShakaStack showcase app** — the multi-tenant dashboard/batch-planning product
built on React on Rails (RSC/streaming fleet view), Shakapacker, Control Plane
Flow, and ShakaPerf, doubling as ShakaCode's public demo and optional hosted
free service. The split is by layer, not a replacement: the **protocol plane
(this Worker + D1) stays as designed** — a demo app's job is to change
frequently, and the mutual-exclusion primitive must never be down because the
demo is being upgraded. The ShakaStack app is the product plane: it consumes
the Worker API for fleet state, owns its own Postgres for product concerns
(users, orgs, saved views), and supersedes the transitional local write app and
Worker-served read view once the protocol plane has proven itself internally.

## Architecture

```text
Codex / Claude Code sessions                     launchd/systemd sidecar
  agent-coord CLI (HttpStore)                      machine-liveness pings
  lifecycle hooks (Claude hooks / Codex notify)          |
        \                |                               |
         \               v                               v
          +----->  Cloudflare Worker (API + read-only dashboard)
                        |            \
                        v             \-- Cloudflare Access (dashboard auth)
                     D1 (SQLite)
                        |
                        +-- cron: TTL sweeps, nightly bot-authored export
                        v
        this repo (git archive: batched daily export, bot identity)
```

Writers, one per record type (per the #4 split-records decision):

- **Agent status**: written only by the agent — via `agent-coord heartbeat` from
  prompt-driven phase transitions, and (proposed) via host lifecycle hooks
  (Claude Code `SessionStart`/`PostToolUse`/`Notification`/`Stop`/`SessionEnd`;
  Codex `notify` events), which give deterministic liveness without prompt tokens
  and a direct `blocked-on-approval` signal. Hooks read lane identity from a
  gitignored lane-context file that `claim` writes into the worktree; absent file
  → hook no-ops. Hook calls are fire-and-forget (1–2s timeout, always exit 0).
- **Machine liveness**: written only by the sidecar. The sidecar never writes
  agent status, which structurally prevents the terminal-status-overwrite
  deadlock (#4 F3).
- **Batches/lanes/cancellation/reservations**: written by coordinators via the
  CLI or dashboard write actions.

## Data model

```sql
CREATE TABLE machines (
  machine     TEXT PRIMARY KEY,
  token_hash  TEXT NOT NULL UNIQUE,
  created_at  TEXT NOT NULL,
  revoked_at  TEXT
);

CREATE TABLE batches (
  batch_id      TEXT PRIMARY KEY,
  repo          TEXT NOT NULL,
  objective     TEXT,
  instructions  TEXT,
  launch_prompt TEXT,
  status        TEXT NOT NULL DEFAULT 'registered',
    -- registered | launch_requested | running | stop_requested | stopped | complete
  machine       TEXT,           -- launch target for #5
  cancelled_at  TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE TABLE lanes (
  batch_id      TEXT NOT NULL,
  name          TEXT NOT NULL,
  owner         TEXT NOT NULL,  -- agent_id
  targets       TEXT NOT NULL,  -- JSON array
  depends_on    TEXT,           -- JSON array of "batch:lane"
  status        TEXT,
  thread_handle TEXT,           -- <batch-short>-<lane>-<word>
  cancelled_at  TEXT,
  PRIMARY KEY (batch_id, name)
);

CREATE TABLE claims (
  repo            TEXT NOT NULL,
  target          TEXT NOT NULL,
  agent_id        TEXT NOT NULL,
  instance_id     TEXT NOT NULL, -- per-session nonce (#4 F2)
  generation      INTEGER NOT NULL DEFAULT 1, -- fencing counter (#4 F1)
  batch_id        TEXT,
  branch          TEXT,
  status          TEXT NOT NULL DEFAULT 'active', -- active | released
  claimed_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL,
  expires_at      TEXT NOT NULL,
  released_at     TEXT,
  released_by     TEXT,
  superseded_from TEXT,          -- previous instance_id on supersede
  PRIMARY KEY (repo, target)
);

CREATE TABLE agent_status (
  agent_id      TEXT PRIMARY KEY,
  instance_id   TEXT NOT NULL,
  repo          TEXT,
  target        TEXT,
  batch_id      TEXT,
  branch        TEXT,
  status        TEXT NOT NULL,
  phase         TEXT,
  thread_handle TEXT,
  generation    INTEGER,        -- echoed claim generation; stale → rejected
  terminal      INTEGER NOT NULL DEFAULT 0, -- sticky unless explicit restart
  updated_at    TEXT NOT NULL,
  expires_at    TEXT NOT NULL
);

CREATE TABLE machine_liveness (
  machine    TEXT PRIMARY KEY,
  updated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE TABLE events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_id    TEXT,
  lane        TEXT,
  agent_id    TEXT,
  instance_id TEXT,
  machine     TEXT,             -- derived from token
  type        TEXT NOT NULL,    -- phase | supersede | takeover | cancel | stop_requested | spawn | ...
  message     TEXT,
  at          TEXT NOT NULL
);

CREATE TABLE reservations (       -- #6
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  machine    TEXT NOT NULL,
  lanes      INTEGER NOT NULL,
  batch_id   TEXT,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
```

## API surface

All endpoints require `Authorization: Bearer <machine token>`; the Worker derives
`machine` from the token. Responses mirror the CLI's existing JSON shapes so
`HttpStore` maps them 1:1 onto current exit codes.

| Endpoint | Semantics |
| --- | --- |
| `POST /v1/claims` | Acquire / renew / supersede (`mode` field). Returns claim incl. generation, or a refusal payload → `CLAIM_REFUSED` (exit 3). |
| `POST /v1/claims/release` | Release; preserves audit fields. |
| `POST /v1/agent-status` | Heartbeat upsert; rejected if terminal-sticky or stale generation. |
| `POST /v1/machine-liveness` | Sidecar ping. |
| `GET /v1/status` | `?scope=all` / `?repo=&target=` / `?batch_id=` — same three scopes and degraded-notes contract as today; includes cancellation and reservations. |
| `PUT /v1/batches/:id` | Register/update batch (registration-first flow). |
| `POST /v1/batches/:id/cancel` | First-class cancellation (batch or `?lane=`); also settable to `launch_requested` for #5. |
| `POST /v1/events` / `GET /v1/events?batch_id=` | Append / list ordered events. |
| `POST /v1/reservations` / `DELETE /v1/reservations/:id` | Capacity reservation (#6), atomic against free capacity. |
| `GET /v1/health` | Doctor target. |
| `GET /dashboard` | Read-only view, behind Cloudflare Access (not bearer tokens). |

## Concurrency semantics

D1 does not support interactive transactions; it does guarantee single-statement
atomicity and atomic `db.batch()`. Every mutual-exclusion decision is therefore
expressed as **one conditional statement**, which is strictly stronger than the
current two-file check-then-act because the liveness check moves *into the
write's WHERE clause*:

- **Acquire with takeover** (closes #4 F1 at the store level):

  ```sql
  INSERT INTO claims (...) VALUES (...)
  ON CONFLICT (repo, target) DO UPDATE SET
    agent_id = excluded.agent_id,
    instance_id = excluded.instance_id,
    generation = claims.generation + 1,
    ...
  WHERE claims.status = 'released'
     OR claims.expires_at < :now
     OR NOT EXISTS (
          SELECT 1 FROM agent_status a
          WHERE a.agent_id = claims.agent_id
            AND :now < datetime(a.updated_at, '+' || 4 * :ttl || ' seconds'))
  ```

  Zero rows changed → refusal. The heartbeat cannot be revived "between the check
  and the write" because check and write are the same statement.

- **Renew** requires matching `agent_id` *and* `instance_id` (closes F2: a
  re-pasted chat has a new instance id and is refused).
- **Supersede** (`mode: supersede`) matches `agent_id`, ignores `instance_id`,
  bumps `generation`, records `superseded_from`, emits a `supersede` event.
- **Fencing**: `agent-status` writes carrying a `generation` older than the
  claim's current one are rejected; a displaced holder learns at its next write.
  The workflow-side push gate is shakacode/agent-workflows#63.
- **Sticky terminal**: status upsert has `WHERE terminal = 0 OR :restart = 1`.
- **Reservations**: insert guarded by a capacity subquery in the same statement.

## Security

- Per-machine bearer tokens, hashed at rest in `machines`; revocation = set
  `revoked_at`. Tokens live in each machine's env (`AGENT_COORD_API_TOKEN`).
- Dashboard read view is gated by Cloudflare Access (email allowlist), not tokens.
- The Worker holds no GitHub credentials; the nightly export runs with a
  bot/machine identity so routine state never appears as human contributions.
- State content (repo names, branches, batch instructions) is org-internal; both
  the Worker route and the D1 database live in the shakacode Cloudflare account.

## Migration and rollback

Per the grill decisions:

1. Deploy Worker + D1; implement `HttpStore` behind `AGENT_COORD_API_URL` +
   `AGENT_COORD_API_TOKEN`. Existing GitHub/local stores untouched.
2. Pilot on shakacode/react_on_rails: drain in-flight batches, set the env vars on
   every machine that touches the repo, run one full batch end-to-end on HTTP.
3. Flip remaining repos. Never mix backends within one repo's active work; no
   dual-write shadow mode (claims are the exclusion primitive — two stores can
   disagree about the winner).
4. Rollback at any point = unset the env vars.
5. Interim relief before cutover: point `AGENT_COORD_REF` at a non-default
   `state` branch so Contents-API commits stop counting toward the operator's
   contribution graph (GitHub counts default-branch and gh-pages commits only).
6. After cutover this repo becomes the audit archive: one bot-authored batched
   export commit per day via Worker cron.

## Risks

- **D1 transaction model**: no interactive transactions. Mitigated by designing
  every exclusion decision as a single conditional statement (above); the parity
  test suite (#3) includes two-writer contention tests.
- **TS/Worker unfamiliarity**: surface kept small (~300 lines, no framework);
  the contract lives in the Ruby CLI tests, not the Worker.
- **Cloudflare outage**: CLI reports operational error (exit 2) and workflows
  already treat that as `private_state: UNKNOWN` with hard-stop rules; rollback
  env vars restore the GitHub store.
- **Hook availability drift** (Claude hook events, Codex `notify` coverage):
  hooks are additive; prompt-driven heartbeats remain the portable floor, so a
  host losing an event degrades resolution, not correctness.
