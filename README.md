# Agent Coordination

CLI, workflow helpers, Worker code, tests, and simulation fixtures for
coordinating concurrent agent work.

The team/client runtime path is the HTTP backend: `AGENT_COORD_API_URL` points
the CLI at the Cloudflare Worker backed by D1, and `AGENT_COORD_API_TOKEN`
authenticates this machine to that Worker. Local file state is for tests and
smoke checks. Advanced fallback backends are available for maintainers, but new
users should start with HTTP.

Keep this public repository code-only. Do not commit live `claims/`,
`heartbeats/`, `batches/`, `*.json.lock`, secrets, environment files, customer
data, credentials, or source-code patches here.

## License

This repository is the MIT License protocol plane for Agent Coordination. That
plane includes the CLI, Cloudflare Worker API, Worker-served read-only
dashboard, simulation harness, tests, documentation, ADRs, and examples.

The runtime state is private data, not product source. Live claims, heartbeats,
batches, lock files, tokens, credentials, customer data, and source-code patches
must stay outside this repository.

A future hosted or monetized ShakaStack product plane can use a different
license and repository boundary. Product-plane dashboards and batch-planning
features should consume the protocol-plane API rather than relicense the
protocol primitives in this repository. The standalone
`shakacode/agent-coordination-dashboard` repository should carry the same MIT
protocol-plane stance while it remains the local/protocol dashboard. See
[ADR 0002](docs/adr/0002-mit-protocol-plane-open-core-boundary.md).

## Setup

```bash
gh auth status
gh repo clone shakacode/agent-coordination
cd agent-coordination
bundle install
git config core.hooksPath .githooks
bundle exec rubocop
ruby -Itest test/agent_coordination_cli_test.rb
bin/agent-coord --help
bin/agent-coord bootstrap
export PATH="$HOME/.local/bin:$PATH"
agent-coord --help
```

The versioned pre-commit hook in `.githooks/pre-commit` runs RuboCop on staged
Ruby files before each commit after `core.hooksPath` is configured. CI runs the
full RuboCop check on every pull request.

## HTTP backend

### Deploy the Worker/D1 backend

Run this once for each Cloudflare environment before provisioning machine
tokens:

```bash
cd worker
npm install
npx wrangler login
npx wrangler d1 create agent-coord
# Copy the printed database_id into worker/wrangler.toml if this is a new D1 DB.
npx wrangler d1 migrations apply agent-coord --remote
npx wrangler deploy
export AGENT_COORD_API_URL=<worker-url>
curl -fsS "$AGENT_COORD_API_URL/v1/health"
cd ..
```

Keep deployment credentials and generated tokens out of git. The CLI only needs
the deployed Worker URL and a machine token at runtime.

Provision one token per machine from the repository root. The command prints the
token once and stores only its SHA-256 hash in D1, so run it in a private
terminal:

```bash
worker/bin/provision-token <machine-name>
```

For local Wrangler/D1 development, pass `--local`:

```bash
worker/bin/provision-token <machine-name> --local
```

Machine names may contain letters, numbers, dots, underscores, colons, and
hyphens. If `wrangler d1 execute` fails, the script preserves Wrangler's output
and, when the failure looks like a duplicate-machine or token constraint, adds a
hint to delete or update the existing D1 `machines` row before re-provisioning.

After the Worker is deployed and this machine has a token, set both HTTP backend
env vars and verify the backend:

```bash
export AGENT_COORD_API_URL=<worker-url>
export AGENT_COORD_API_TOKEN=<machine-token>
agent-coord doctor
```

Backend selection follows this rule:

1. `--state-root` flag -> `LocalStore`
2. `--api-url` flag or `AGENT_COORD_API_URL` env -> `HttpStore`
3. `AGENT_COORD_STATE_ROOT` env -> `LocalStore`
4. otherwise -> legacy `GitHubStore`

When both `AGENT_COORD_API_URL` and `AGENT_COORD_STATE_ROOT` are set, the CLI
uses the HTTP backend and warns once. Pass `--state-root` only for an explicit
local smoke check.

React on Rails workflow docs assume `agent-coord` is available on `PATH`.
`bin/agent-coord bootstrap` installs `agent-coord` into `$HOME/.local/bin` by
default and appends that directory to the current shell profile. Use
`--install-dir PATH` to choose another directory or `--no-profile` to skip
profile edits. If the shell has not reloaded the profile yet, export the path in
the active terminal:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Run `agent-coord doctor` after setup. The default doctor is intentionally
lightweight: it verifies backend access and the expected state layout without
downloading and parsing every JSON record. Use `agent-coord doctor --deep` for a
full audit that parses every claim, heartbeat, and batch file. If doctor fails,
agents should report coordination state as `UNKNOWN` and use the public
claim-comment fallback until the operator fixes backend access.

For local smoke checks, set `AGENT_COORD_STATE_ROOT` or pass `--state-root` to
use a temporary filesystem state directory:

```bash
STATE_ROOT=$(mktemp -d)
AGENT_COORD_STATE_ROOT="$STATE_ROOT" agent-coord heartbeat \
  --agent-id worker-3969 \
  --repo shakacode/react_on_rails \
  --target 3969 \
  --batch-id batch-2026-06-13 \
  --branch jg-codex/3969-agent-coord-backend
AGENT_COORD_STATE_ROOT="$STATE_ROOT" agent-coord status
rm -rf "$STATE_ROOT"
```

## CLI

```text
bin/agent-coord claim     --agent-id ID --repo OWNER/REPO --target ISSUE_OR_PR [--batch-id ID] [--branch BRANCH] [--metadata options] [--ttl SECONDS]
bin/agent-coord release   --agent-id ID --repo OWNER/REPO --target ISSUE_OR_PR [--metadata options]
bin/agent-coord heartbeat --agent-id ID [--repo OWNER/REPO] [--target ISSUE_OR_PR] [--batch-id ID] [--branch BRANCH] [--metadata options] [--status STATUS]
bin/agent-coord register-batch --file PATH
bin/agent-coord status [--json]
bin/agent-coord status --repo OWNER/REPO --target ISSUE_OR_PR [--json]
bin/agent-coord status --batch-id ID [--json]
bin/agent-coord version [--json]
bin/agent-coord config [show] [--json]
bin/agent-coord doctor [--json] [--deep] [--state-root PATH]
bin/agent-coord bootstrap [--install-dir PATH] [--profile PATH] [--no-profile]
```

`claim` acquires or renews a lease. If an active claim exists for another agent,
the holder's heartbeat is the normal liveness source: `live` or `stale`
heartbeats refuse takeover, while a `dead` heartbeat allows takeover. If the
holder heartbeat is missing or invalid, `expires_at` is the safe fallback and the
claim can be taken over only after that fallback has passed. Existing claim
updates use the active store's compare-and-swap token, so competing updates fail
instead of silently overwriting each other.

Metadata options available on `claim`, `heartbeat`, and `release` are
`--thread-handle`, `--chat-handle`, `--host`, `--pr-url`, `--dashboard-url`,
`--operator`, `--phase`, `--generation`, and `--instance-id`. These fields are
additive, optional, and included in JSON status output when present. Workers use
them to connect a lane, chat, host app, branch, PR, operator, and dashboard deep
link without parsing handoff prose.

`register-batch --file PATH` validates and writes a JSON batch manifest to
`batches/<batch-id>.json` using the active store. It stamps `schema_version`,
`registered_at`, and `updated_at`, preserves optional operator/dashboard/thread
metadata, and rejects malformed lane names or owner/target fields before workers
claim lanes.

`heartbeat` upserts `heartbeats/<agent-id>.json`. `status` renders coordination
state in text or JSON. Full `status` renders compact claims, heartbeats, batch
lanes, lane dependencies, and blocked-on refs for broad audits. Scoped status is
the preferred batch-workflow path:

- `status --repo OWNER/REPO --target ISSUE_OR_PR` reads only
  `claims/<owner>/<repo>/<issue-or-pr>.json` and that claim holder's heartbeat
  when a holder exists.
- `status --batch-id ID` reads only `batches/<id>.json`, lane-owner heartbeats,
  and dependency batch files plus referenced lane-owner heartbeats needed to
  compute `blocked_on`.

Scoped JSON payloads include `scope` and `degraded` fields. A scoped command can
show `degraded` notes for intentionally omitted unrelated state, such as claims
not checked in batch scope; that is different from exit 2. Exit 2 means the
coordination backend result is `UNKNOWN` for that command. Text status renders the
same degraded notes as a footer when rows are present. In large backends, prefer
target or batch scoped status for React on Rails batch lanes and treat a timed
out full coordination read as degraded/`UNKNOWN` rather than guessing.
`release` marks a claim released while preserving the record for auditability.
`version` prints the CLI contract version. `config show --json` prints runtime
defaults and machine-readable exit codes. Default `doctor` verifies the current
backend without writing state or parsing every record; `doctor --deep` adds full
JSON validation. `bootstrap` installs the `agent-coord` command used by public
workflow docs.

## CLI Contract And Exit Codes

Use `agent-coord version --json` and `agent-coord config show --json` as the
stable contract for public workflow docs. Public repos should avoid copying
private implementation defaults when they can point agents at these commands.

Current exit code contract:

| Exit | Meaning                                  | Agent behavior                                                                 |
| ---- | ---------------------------------------- | ------------------------------------------------------------------------------ |
| 0    | Command succeeded                         | Use the returned state.                                                        |
| 1    | Usage error                               | Fix the command invocation before proceeding.                                  |
| 2    | Operational failure                       | Report coordination state as `UNKNOWN`; use advisory fallback when safe.       |
| 3    | `CLAIM_REFUSED` by live/stale/active hold | Hard stop for machine agents; report holder/liveness instead of competing.     |

A refused claim is intentionally different from a bootstrap/auth/network
failure. A machine agent may not override exit 3 on its own. Exit 2 means the
backend could not be trusted for that command, including storage-level compare
and-swap contention; dependency-sensitive lanes should stop with `UNKNOWN` until
the coordinator restores backend access.

## Heartbeat Liveness

Heartbeat liveness is derived from timestamps:

- `now < expires_at` -> `live`
- `expires_at <= now < updated_at + 4 * ttl` -> `stale`
- `now >= updated_at + 4 * ttl` -> `dead`

`ttl` is the interval between `updated_at` and `expires_at`. Use short heartbeat
TTLs, normally 15 minutes. A stale heartbeat is a warning that the agent may be
thinking, offline, or between tool calls. A dead heartbeat means claims held by
that agent are recoverable.

Workers should refresh heartbeats at every phase transition: item start, branch
or PR update, review pass, blocked state, and done state. Long-running desktop
sessions should also use the platform scheduler templates so liveness does not
depend on the agent being between tool calls.

## Scheduler Renewal

### macOS launchd

The `launchd/com.shakacode.agent-coord-heartbeat.plist.example` template refreshes
one heartbeat every 5 minutes. Install one heartbeat job per live batch lane:

```bash
export AGENT_ID=m5-codex-batch2
export TARGET_REPO=shakacode/react_on_rails
export TARGET=3970
export BATCH_ID=agent-coord-2026-06-13
export BRANCH=jg-codex/3969-agent-coord-backend
export AGENT_COORD_REPO="$(pwd)"
export AGENT_COORD_ENV_FILE="$HOME/.config/agent-coord/env"
mkdir -p "$(dirname "$AGENT_COORD_ENV_FILE")"
install -m 600 /dev/null "$AGENT_COORD_ENV_FILE"
cat > "$AGENT_COORD_ENV_FILE" <<'EOF'
AGENT_COORD_API_URL=<worker-url>
AGENT_COORD_API_TOKEN=<machine-token>
EOF
perl -pe 's#__AGENT_ID__#$ENV{AGENT_ID}#g;
          s#__TARGET_REPO__#$ENV{TARGET_REPO}#g;
          s#__TARGET__#$ENV{TARGET}#g;
          s#__BATCH_ID__#$ENV{BATCH_ID}#g;
          s#__BRANCH__#$ENV{BRANCH}#g;
          s#__AGENT_COORD_ENV_FILE__#$ENV{AGENT_COORD_ENV_FILE}#g;
          s#__AGENT_COORD_REPO__#$ENV{AGENT_COORD_REPO}#g' \
  launchd/com.shakacode.agent-coord-heartbeat.plist.example \
  > "$HOME/Library/LaunchAgents/com.shakacode.agent-coord-heartbeat.${AGENT_ID}.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.shakacode.agent-coord-heartbeat.${AGENT_ID}.plist"
```

You can also replace the `__PLACEHOLDER__` values manually. Keep the env file
private (`chmod 600`) and never commit it. The checked-in template loads
`AGENT_COORD_API_URL` and `AGENT_COORD_API_TOKEN` from that local file instead
of storing token values in the repository.

### Linux systemd --user

The `systemd/agent-coord-heartbeat.service.example` template runs the same
heartbeat loop under `systemd --user`. Install one service per live batch lane,
substituting the same placeholders used by the launchd template:

```bash
mkdir -p "$HOME/.config/systemd/user"
sed -e "s#__AGENT_ID__#${AGENT_ID}#g" \
    -e "s#__TARGET_REPO__#${TARGET_REPO}#g" \
    -e "s#__TARGET__#${TARGET}#g" \
    -e "s#__BATCH_ID__#${BATCH_ID}#g" \
    -e "s#__BRANCH__#${BRANCH}#g" \
    -e "s#__AGENT_COORD_ENV_FILE__#${AGENT_COORD_ENV_FILE}#g" \
    -e "s#__AGENT_COORD_REPO__#${AGENT_COORD_REPO}#g" \
    systemd/agent-coord-heartbeat.service.example \
    > "$HOME/.config/systemd/user/agent-coord-heartbeat.${AGENT_ID}.service"
systemctl --user daemon-reload
systemctl --user enable --now "agent-coord-heartbeat.${AGENT_ID}.service"
```

The systemd template loads the same private env file for
`AGENT_COORD_API_URL` and `AGENT_COORD_API_TOKEN`.

## State Layout

Runtime state lives in these directories:

```text
claims/<owner>/<repo>/<issue-or-pr>.json
heartbeats/<agent-id>.json
batches/<batch-id>.json
```

The checked-in `.gitkeep` files only preserve the directories. Schema examples
are documented below rather than committed as live JSON records, so `status`
does not show fake work.

## Claim Schema

```json
{
  "schema_version": 1,
  "repo": "shakacode/react_on_rails",
  "target": "3969",
  "agent_id": "worker-3969",
  "batch_id": "batch-2026-06-13",
  "branch": "jg-codex/3969-agent-coord-backend",
  "thread_handle": "batch13-backend-quokka",
  "host": "codex",
  "operator": "justin",
  "phase": "claimed",
  "generation": 3,
  "instance_id": "m5-codex-20260708T180000Z",
  "status": "active",
  "claimed_at": "2026-06-13T00:30:00Z",
  "updated_at": "2026-06-13T00:30:00Z",
  "expires_at": "2026-06-13T04:30:00Z"
}
```

Required fields: `schema_version`, `repo`, `target`, `agent_id`, `status`,
`claimed_at`, `updated_at`, `expires_at`.

Allowed `status` values for the initial lifecycle are `active` and `released`.
Coordinators should treat a claim holder with a `dead` heartbeat as recoverable
even if the claim `expires_at` timestamp is still in the future. `expires_at`
remains useful for audit and as the fallback when the heartbeat is missing or
invalid.

Optional lane metadata fields on claims are `thread_handle`, `chat_handle`,
`host`, `pr_url`, `dashboard_url`, `operator`, `phase`, `generation`, and
`instance_id`. `release` preserves the existing claim record and may update the
same metadata fields for terminal states, such as adding a final `pr_url` or
`phase`.

## Heartbeat Schema

```json
{
  "schema_version": 1,
  "agent_id": "worker-3969",
  "repo": "shakacode/react_on_rails",
  "target": "3969",
  "batch_id": "batch-2026-06-13",
  "branch": "jg-codex/3969-agent-coord-backend",
  "thread_handle": "batch13-backend-quokka",
  "host": "codex",
  "pr_url": "https://github.com/shakacode/react_on_rails/pull/3969",
  "dashboard_url": "https://coord.example.test/batches/batch-2026-06-13/backend",
  "operator": "justin",
  "phase": "validating",
  "generation": 3,
  "instance_id": "m5-codex-20260708T180000Z",
  "status": "in_progress",
  "updated_at": "2026-06-13T00:40:00Z",
  "expires_at": "2026-06-13T00:55:00Z"
}
```

Required fields: `schema_version`, `agent_id`, `status`, `updated_at`,
`expires_at`.

Optional lane metadata fields on heartbeats are `thread_handle`, `chat_handle`,
`host`, `pr_url`, `dashboard_url`, `operator`, `phase`, `generation`, and
`instance_id`. Status readers should treat missing metadata as `UNKNOWN` rather
than inferring it from branch names or handoff text.

## Batch Schema

```json
{
  "schema_version": 1,
  "batch_id": "batch-2026-06-13",
  "repo": "shakacode/react_on_rails",
  "objective": "Ship backend and docs updates",
  "operator": "justin",
  "dashboard_url": "https://coord.example.test/batches/batch-2026-06-13",
  "lanes": [
    {
      "name": "backend",
      "owner": "worker-3969",
      "targets": ["3969"],
      "thread_handle": "thread-backend",
      "host": "m5",
      "pr_url": "https://github.com/shakacode/react_on_rails/pull/3969",
      "depends_on": []
    },
    {
      "name": "docs",
      "owner": "worker-3972",
      "targets": ["3972"],
      "thread_handle": "thread-docs",
      "host": "m1",
      "depends_on": ["batch-2026-06-13:backend"]
    }
  ],
  "registered_at": "2026-06-13T00:30:00Z",
  "updated_at": "2026-06-13T00:30:00Z"
}
```

Required manifest fields before registration: `batch_id` and non-empty `lanes`.
`register-batch` writes `schema_version`, `registered_at`, and `updated_at`.

Each lane should include `name`, `owner`, and `targets`. `owner` is the stable
agent id used by `heartbeat`, so `status` can attach the lane's latest heartbeat
status and liveness. Lane names must not contain `:`; batch ids may contain `:`.
`depends_on` is optional and accepts a string or array of lane refs in the form
`<batch-id>:<lane-name>`, split at the last colon.

Top-level batch metadata such as `repo`, `objective`, `instructions`, `operator`,
`dashboard_url`, and lane metadata such as `thread_handle`, `chat_handle`,
`host`, `pr_url`, `dashboard_url`, `operator`, and `phase` are preserved and
included in JSON status output. A dependency is considered met when the
referenced lane owner's heartbeat reports a terminal status such as `done`,
`complete`, `completed`, `merged`, or `ready`. A released claim is preserved for
auditability and does not unblock dependent lanes by itself. Unmet dependencies
appear in the lane's `blocked_on` field:

```text
batches
- batch-2026-06-13
  - lane backend owner worker-3969 targets 3969 status in_progress live deps - blocked_on -
  - lane docs owner worker-3972 targets 3972 status blocked live deps batch-2026-06-13:backend blocked_on batch-2026-06-13:backend
```

Workers with unmet dependencies should set their own heartbeat to `blocked`,
switch to another independent lane, and check `agent-coord status` again before
resuming, rebasing, or pushing dependency-sensitive work.

## Lifecycle

1. Coordinator registers a batch manifest describing lanes and dependencies.
2. Worker acquires a claim for its issue or PR target.
3. Worker refreshes a heartbeat during active work.
4. Coordinator uses targeted `status --repo ... --target ...` or
   `status --batch-id ...` for lane decisions, and full `status` only for broad
   audits where an all-state scan is acceptable.
5. Worker releases the claim or lets the lease expire if the session is lost.

Keep leases short enough that abandoned work is recoverable, usually 2-4 hours
for active batch claims and 15 minutes for heartbeats.
