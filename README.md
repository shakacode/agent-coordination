# Agent Coordination

CLI, workflow helpers, Worker code, tests, and simulation fixtures for
coordinating concurrent agent work.

A zero-config first run uses a clearly labeled local store so one person can
try the CLI immediately. The team and multi-machine runtime path is the HTTP
backend: `AGENT_COORD_API_URL` points the CLI at the Cloudflare Worker backed by
D1, and `AGENT_COORD_API_TOKEN` authenticates this machine to that Worker. The
legacy GitHub backend is available only when explicitly requested by
maintainers.

Keep this public repository code-only. Do not commit live `claims/`,
`heartbeats/`, `batches/`, `events/`, `*.json.lock`, secrets, environment files,
customer data, credentials, or source-code patches here.

## License

This repository is the MIT License protocol plane for Agent Coordination. That
plane includes the CLI, Cloudflare Worker API, Worker-served read-only
dashboard, simulation harness, tests, documentation, ADRs, and examples.

The runtime state is private data, not product source. Live claims, heartbeats,
batches, events, lock files, tokens, credentials, customer data, and source-code
patches must stay outside this repository.

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
agent-coord status
agent-coord demo
```

The versioned pre-commit hook in `.githooks/pre-commit` runs RuboCop on staged
Ruby files before each commit after `core.hooksPath` is configured. CI runs the
full RuboCop check on every pull request.

## CLI package preparation

The CLI supports Ruby 3.2 or newer. This repository pins a current Ruby version
for development and CI also runs the Ruby suite on the supported floor.

The `agent-coordination` RubyGem installs only the `agent-coord` CLI and its
public documentation; the Worker deployment remains source-only. The gem has not been published.
Build and install it locally to verify the distribution without changing a
registry, tag, or release:

```bash
gem build agent-coordination.gemspec
```

Replace `VERSION` with the version in the filename printed by `gem build`.

```bash
gem install --local ./agent-coordination-VERSION.gem
agent-coord version --json
rm ./agent-coordination-VERSION.gem
```

Generated `.gem` files are local artifacts and should not be committed. See the
[Changelog](CHANGELOG.md) for release-facing changes and the
[Worker state protocol with `curl`](docs/protocol-curl.md) for placeholder-only
HTTP examples.

## Zero-config local first run

Run `agent-coord status` without configuring a backend. The CLI uses
`$XDG_STATE_HOME/agent-coordination` when `XDG_STATE_HOME` is an absolute path.
Relative, empty, or unset values use `~/.local/state/agent-coordination`.
Every command that selects this implicit default prints its path with a
`local mode — single-machine only` notice. JSON commands keep machine-readable
output on stdout; the notice goes to stderr.

This default is for one machine only. Configure the HTTP backend before sharing
coordination state across machines or operators. If a consumer env file already
configures `AGENT_COORD_API_URL`, this implicit default is refused for write
commands; see the split-brain hard stop under backend selection, and set
`AGENT_COORD_LOCAL=1` when single-machine local state is what you want.

Run the deterministic walkthrough to see the claim and heartbeat model without
configuring or changing any persistent backend:

```bash
agent-coord demo
```

The demo uses an isolated temporary local store, shows a live-holder claim
refusal followed by stale and dead heartbeat states and a successful takeover,
then removes its temporary state. It ignores configured HTTP and legacy GitHub
backends, so it never writes demo data remotely.

## HTTP backend

### Deploy the Worker/D1 backend

Run this once for each Cloudflare environment before provisioning machine
tokens:

```bash
cd worker
npm install
npx wrangler login
npx wrangler d1 create agent-coord
# In wrangler.toml, replace the all-zero database_id with the ID printed above.
# Keep that deployment-specific substitution out of commits.
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
worker/bin/provision-token <machine-name> \
  --read-prefix <read-prefix> \
  --write-prefix <write-prefix>
```

Token provisioning requires at least one read or write prefix. An omitted scope
dimension receives no access (`[]`). Use repeatable flags when a machine needs
multiple path scopes:

```bash
worker/bin/provision-token m5 \
  --read-prefix claims/shakacode/react_on_rails \
  --read-prefix heartbeats \
  --write-prefix claims/shakacode/react_on_rails \
  --write-prefix heartbeats/m5-codex.json
```

For a trusted single-operator deployment that intentionally needs unrestricted
access, pass `--all-state` instead of prefix flags:

```bash
worker/bin/provision-token <machine-name> --all-state
```

After a D1 rotation, target the replacement database explicitly and use
`--rotate` so an existing machine row is updated or a missing row is inserted:

```bash
worker/bin/provision-token <machine-name> \
  --database <database-name> \
  --rotate \
  --all-state
```

Use explicit `--read-prefix` and `--write-prefix` flags instead of
`--all-state` when the consumer needs narrower access. The token is printed
once; persist it immediately in the consumer's private environment file. See
[the backend rotation runbook](docs/runbooks/rotate-backend.md) for the complete
database, token, restart, and verification sequence.

The stored empty scope (`""`) grants all state, but the provisioning command
does not accept an empty prefix as a shortcut; all-state access must use the
explicit flag. A directory scope such as
`claims/shakacode/react_on_rails` covers descendant paths. A valid record-path
scope such as `heartbeats/m5-codex.json` covers exactly that flat record. The
Worker enforces read scopes for `GET /v1/state/<path>` and
`GET /v1/state?prefix=...`, write scopes for `PUT /v1/state/<path>`, and records
the authenticated machine as `updated_by` on each state write. Active-path
`DELETE` requires write coverage for both the active path and its
`archive/<path>` mirror; archive-path `DELETE` requires archive write coverage.
Ordinary active-only writer tokens therefore cannot delete, while GC tokens use
explicit active-plus-archive mirrors or the trusted all-state scope. Claim takeover
checks may need read access to the current holder's heartbeat; use an exact
heartbeat write scope only when the machine's agent id is stable.
Active state paths are limited to 512 UTF-8 bytes. Mirrored archive paths allow
520 bytes total for the `archive/` prefix plus that same at-most-512-byte active
suffix; an archive path cannot carry a longer original suffix.
When listing a parent prefix above a scoped token's read scope, the Worker
returns only covered descendants. Claims-scoped tokens can pass the default
`agent-coord doctor` read probe; tokens scoped only to other prefixes should use
`agent-coord doctor --doctor-prefix <read-prefix>`. Directory prefixes are
checked with the list endpoint; exact record-path prefixes such as
`heartbeats/m5-codex.json` are checked with a record read. The provisioning
script rejects a command with no scope flags and rejects combining prefix flags
with `--all-state`. Read-only tokens support status and doctor workflows.
Write-only tokens support append-only callers such as `record-event`; claim,
release, heartbeat, and batch mutation commands read existing state before
writing and therefore need matching read prefixes.

For local Wrangler/D1 development, pass `--local`:

```bash
worker/bin/provision-token dev --local \
  --read-prefix claims \
  --write-prefix claims
```

Machine names may contain letters, numbers, dots, underscores, colons, and
hyphens. Database names may contain letters, numbers, dots, underscores, and
hyphens. If `wrangler d1 execute` fails, the script preserves Wrangler's output.
Use `--rotate` when re-keying an existing machine.

After the Worker is deployed and this machine has a token, set both HTTP backend
env vars and verify the backend:

```bash
export AGENT_COORD_API_URL=<worker-url>
export AGENT_COORD_API_TOKEN=<machine-token>
agent-coord doctor
```

### Machine and session identity

Each machine also exports one static, non-secret machine identifier so
coordination writes carry machine/session attribution:

```sh
# M5
export AGENT_COORD_MACHINE_ID=m5

# M1
export AGENT_COORD_MACHINE_ID=m1-codex
```

Session identity resolves in this order and is never reused from a stale
persistent value:

1. `AGENT_COORD_SESSION_ID` — explicit caller-supplied session or run id
2. `CODEX_THREAD_ID` — supplied automatically by Codex sessions
3. unset — writes omit session attribution rather than guessing

Every `claim`, `release`, `heartbeat`, and `record-event` write stamps the
resolved tuple into the record as `machine_id`, `session_id`, and
`session_source` (`agent_coord_session_id` or `codex_thread_id`), and
`status --json` projects the same fields back to consumers. Terminal closeouts
use `AGENT_COORD_MACHINE_ID` for `closed_by.machine`, falling back to `--host`
when the variable is unset. Blank values are treated as unset. The tuple is
atomic per write, in both directions: when a write declares a machine id that
differs from the record's last recorded machine and resolves no session, the
stale session fields are cleared rather than paired with the new machine, and
when a write resolves a session that differs from the record's last recorded
session without declaring a machine, the stale machine id is cleared rather
than paired with the new session.

These variables are attribution metadata only: they must never contain token or
secret values, and machine-token authentication remains authoritative for
access control. Machine provisioning happens outside this repository — add
`AGENT_COORD_MACHINE_ID` to each machine's shell profile and to the private
launchd/systemd env file described below so launch templates propagate the
tuple to background heartbeats.

`agent-coord doctor --deep` (any backend) reports the resolved tuple in text
output and under `environment_identity` in `doctor --deep --json`, including
the session resolution source, the authenticated `token_machine` when the deep
HTTP doctor ran, and a `machine_match` status of `match`, `mismatch`, or
`unverified`. The lightweight doctor output is unchanged. When
`agent-coord doctor --deep` runs against the HTTP backend and
`AGENT_COORD_MACHINE_ID` does not match the `/v1/whoami` machine, doctor still
emits its report, then fails with exit code `2`, because a mismatch usually
means the wrong machine token or machine id is installed. The stack doctor
carries the same tuple as an `identity.machine` component check: `failed` on a
mismatch (driving exit `2`), `healthy` on a verified match, and `skipped` when
no authenticated token machine is available to compare.

Backend selection follows this rule:

1. `--state-root` flag -> `LocalStore`
2. `--api-url` flag or `AGENT_COORD_API_URL` env -> `HttpStore`
3. `AGENT_COORD_STATE_ROOT` env -> `LocalStore`
4. `--backend` flag or `AGENT_COORD_BACKEND` env -> legacy `GitHubStore`
5. otherwise -> labeled local store at the zero-config path above

When both `AGENT_COORD_API_URL` and `AGENT_COORD_STATE_ROOT` are set, the CLI
uses the HTTP backend and warns once. Pass `--state-root` only for an explicit
local smoke check.

Selection 5 is *implicit* local. When a consumer env file
(`AGENT_COORD_ENV_FILE`, `$XDG_CONFIG_HOME/agent-coord/env`, or
`$XDG_CONFIG_HOME/agent-coord/http-env.sh`) configures `AGENT_COORD_API_URL`
but that file was never sourced, an implicit local run is a split-brain
configuration: writes would land on a local state root the fleet never reads.
`claim`, `release`, `heartbeat`, `record-event`, and `register-batch` therefore
hard stop with exit `2` and name the offending env file. Read commands
(`status`, `batch-audit`) keep the advisory warning and still succeed. Choose a
backend explicitly to proceed: source the env file for fleet writes, pass
`--state-root PATH` (or set `AGENT_COORD_STATE_ROOT`) for an explicit local
root, or set `AGENT_COORD_LOCAL=1` to opt into implicit local mode.
`AGENT_COORD_LOCAL` accepts `1`, `true`, or `yes` (case-insensitive); any other
value, including empty and `0`, is not an opt-in. The opt-in also silences the
advisory warning for read commands.

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
downloading and parsing every JSON record. On an unconfigured first run it
initializes and verifies the zero-config local root. For an explicitly selected
legacy GitHub backend, it also rejects an archived repository because archived
repositories remain readable but cannot accept coordination writes. Run
`agent-coord doctor --deep` for a full audit. On the HTTP backend it reports a
separate result for claims, heartbeats, batches, and events plus the authenticated
machine and its scopes. A stale or unknown token names the failing resource and
prints the token-rotation command. If a consumer env file configures an API URL
while `status` or `doctor` resolves to local storage, the CLI emits a split-brain
warning. When `doctor` itself resolved to the *implicit* local backend under
that configuration, it emits its full report with `status: split_brain` plus a
`split_brain_env_file` field naming the env file, then exits `2`; the same
explicit opt-ins that unblock writes (`--state-root`, `AGENT_COORD_STATE_ROOT`,
`AGENT_COORD_LOCAL=1`) return it to `ok` and exit `0`. If an explicitly
configured backend fails, agents should report
coordination state
as `UNKNOWN` and use the public claim-comment fallback until the operator fixes
backend access.
For HTTP tokens scoped outside `claims`, pass a readable scope:
`agent-coord doctor --doctor-prefix events/<batch-id>`.

Stack aggregators should invoke `agent-coord doctor --stack-json --deep` with
exactly one direct backend selector: `--state-root PATH`, `--api-url URL`, or
`--backend OWNER/REPO`. Environment defaults still participate in normal backend
resolution, but do not satisfy this machine-contract selector requirement. The
explicit stack output is the component contract v1: it reports
`agent-coordination` as `healthy`, `degraded`, or `failed`, with normalized
checks for CLI version readiness, backend readability, deep resource
evidence, and machine identity (`identity.machine`, which fails on an
environment-versus-token machine mismatch and is skipped when unverifiable).
Exit codes are `0` for healthy, `1` for degraded, `2` for failed, and
`64` for invalid usage. Usage errors emit no JSON. `--stack-json` is strictly
read-only: it never creates a missing explicit local state root, and reports
that missing root as a failed component rather than falling back. Omit `--deep`
only when a shallow report with skipped resource evidence is intentional.
Legacy text and `doctor --json` output remain unchanged.

For `LocalStore`, the explicitly selected top-level state root is an
operator-owned trust boundary and may itself be a symlink. Deep reads fail
closed when a top-level state prefix such as `claims/`, or any directory or
record below it, is a symlink. These are check-then-use guards for cooperative
local state, not atomic filesystem traversal: another process able to rewrite
the tree concurrently under the same local owner is inside that trust boundary.

To override the default for a local smoke check, set `AGENT_COORD_STATE_ROOT` or
pass `--state-root` to use a temporary filesystem state directory. Both are
explicit local selections, so neither trips the split-brain hard stop
(`AGENT_COORD_LOCAL=1` keeps the implicit default instead):

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
bin/agent-coord release   --agent-id ID --repo OWNER/REPO --target ISSUE_OR_PR [--metadata options] [--handoff-to ID] [--handoff-note TEXT] [--terminal done|abandoned|superseded] [--pr-state STATE] [--evidence-url URL] [--workspace WORKSPACE]
bin/agent-coord heartbeat --agent-id ID [--repo OWNER/REPO] [--target ISSUE_OR_PR] [--batch-id ID] [--branch BRANCH] [--metadata options] [--status STATUS]
bin/agent-coord register-batch --file PATH [--launch-prompt PATH|-]
bin/agent-coord record-event --batch-id ID --type TYPE [--lane NAME] [--agent-id ID] [--repo OWNER/REPO] [--target ISSUE_OR_PR] [--branch BRANCH] [--status STATUS] [--metadata options] [--message TEXT]
bin/agent-coord status [--json] [--include-archived]
bin/agent-coord status --repo OWNER/REPO --target ISSUE_OR_PR [--json]
bin/agent-coord status --batch-id ID [--json]
bin/agent-coord batch-audit --batch-id ID [--json]
bin/agent-coord version [--json]
bin/agent-coord config [show] [--json]
bin/agent-coord doctor [--json|--stack-json] [--deep] [--doctor-prefix PREFIX] [--state-root PATH|--api-url URL|--backend OWNER/REPO]
bin/agent-coord gc (--dry-run|--execute) [--json] [--hot-days DAYS] [--archive-days DAYS] [--synthetic-hot-days DAYS]
bin/agent-coord bootstrap [--install-dir PATH] [--profile PATH] [--no-profile]
bin/agent-coord demo
```

`demo` is a deterministic, isolated local walkthrough. It does not use backend
environment variables, make remote requests, or preserve its temporary state.

`claim` acquires or renews a lease. If an active claim exists for another agent,
the holder's heartbeat is the normal liveness source: `live` or `stale`
heartbeats refuse takeover, while a `dead` heartbeat allows takeover. If the
holder heartbeat is missing or invalid, `expires_at` is the safe fallback and the
claim can be taken over only after that fallback has passed. Existing claim
updates use the active store's compare-and-swap token, so competing updates fail
instead of silently overwriting each other.

Metadata options available on `claim`, `heartbeat`, and `release` are
`--thread-handle`, `--chat-handle`, `--host`, `--pr-url`, `--dashboard-url`,
`--operator`, `--phase`, `--generation`, `--instance-id`, `--synthetic`, and
`--synthetic-kind`. These fields are
additive, optional, and included in JSON status output when present. Workers use
them to connect a lane, chat, host app, branch, PR, operator, and dashboard deep
link without parsing handoff prose.

`release --handoff-to ID --handoff-note TEXT` is the structured handoff path for
moving work between agents, hosts, machines, or operators. The released claim is
stamped with `release_mode: "handoff"` plus `handoff_to` and `handoff_note`, so
the next claimant can recover the branch, PR, phase, and resume note from the
target-scoped record. The handoff fields ride along on the auto-emitted
`claim.released` event described under "Auto-emitted lifecycle events" below.

`release --terminal done|abandoned|superseded` records a version-2
`lane_closed` event before releasing the held claim, then stamps the matching
registered lane. The last terminal lane changes its batch manifest to
`status: "completed"`. Terminal release is mutually exclusive with handoff and
requires a claim with `batch_id`. `--pr-state` records the final pull-request
state; `--evidence-url` can point at replayable closeout evidence.

`register-batch --file PATH` validates and writes a JSON batch manifest to
`batches/<batch-id>.json` using the active store. Pass `--launch-prompt PATH` to
read the exact coordination prompt from a file, or `--launch-prompt -` to read it
from stdin; the explicit option overrides any `launch_prompt` already present in
the manifest. Registration stamps `schema_version`, `registered_at`, and
`updated_at`, preserves optional operator/dashboard/thread metadata, and rejects
malformed lane names or owner/target fields before workers claim lanes.
`--synthetic --synthetic-kind KIND` stamps batch-level simulation provenance;
re-registration preserves those fields when a later manifest and command omit
them, so completed synthetic batches retain the one-day GC window.

`record-event` appends immutable batch or lane events under
`events/<batch-id>/<event-id>.json`. Use it for phase changes and noteworthy
operator-visible milestones that should remain visible even when a heartbeat is
overwritten by the next phase. Event records accept the same optional metadata
fields as claims and heartbeats, plus `--type`, `--lane`, and `--message`. Most
claim-lifecycle events are now emitted automatically (see below); use direct
`record-event` for additional operator breadcrumbs.

### Auto-emitted lifecycle events

`claim`, `release`, and `heartbeat` auto-emit lifecycle events so a claim's
acquire, phase transitions, and release leave a queryable trail under
`events/<batch-id>/` without any explicit `record-event` calls. Each emit is
best-effort (a failed event write warns on stderr and never fails the underlying
operation) and only happens when a `batch_id` is known for the operation:

- `claim.acquired` on a genuine claim acquisition or takeover — carries the
  agent, target, branch, and any `phase`/`generation`/`instance-id` metadata on
  the claim. A same-holder TTL renewal with an unchanged lane and unchanged
  generation/instance is treated as a routine renewal and emits nothing.
- `claim.released` on every non-terminal `release` — carries the final claim
  `status`, and for handoffs the `release_mode: "handoff"`, `handoff_to`, and
  `handoff_note` fields. Terminal releases emit the richer `lane_closed` event
  instead and do not double-emit `claim.released`.
- `phase.changed` on a `heartbeat` whose `--phase` differs from the phase on the
  record it overwrote — carries `previous_phase` and the new `phase`. It fires
  only on an actual transition between two phases, never on every beat; the first
  phase assignment is captured by `claim.acquired` instead.

Ordinary phase, lifecycle, and milestone events use timestamp-plus-random IDs and
remain append-only. `lane_closed` is the deliberate exception: its event ID is
a deterministic reservation derived from the lane name, stable within the
batch. A create-only write to that path makes concurrent or retried closeout
idempotent; the first event is authoritative and a conflicting closeout cannot
append a second terminal record for the lane.

Hosts that separate event production from claim release can write the same
terminal record with `record-event --type lane_closed --terminal STATE`, plus
`--batch-id`, `--agent-id`, `--repo`, and `--target`. `--lane` is optional when
the target uniquely identifies one registered lane. Terminal events
default `workspace` to `default` and identify the closer in `closed_by` using
the agent id and `--host` machine value. The public producer/consumer contract
is [`contracts/state-schema-v2.json`](contracts/state-schema-v2.json).

### Typed operational-signal events

`record-event` recognizes four typed `--type` names for the operational signals
most worth counting. Each validates its required fields at write time and rejects
a missing field or out-of-set value with a clear error and a non-zero exit; the
values are stored as additive payload fields on the event record and projected
into `status --batch-id --json` events (present-only). Typing is strict: a typed
event also rejects any typed field that belongs to a *different* typed type (for
example `--type help_requested --severity P1` is an error), so a typed record
carries only its own fields. Any other `--type` value stays allowed and
unvalidated, exactly as before, so free-form breadcrumbs are unaffected.

| `--type`               | Required fields                                    | Allowed values                                              |
| ---------------------- | -------------------------------------------------- | ---------------------------------------------------------- |
| `help_requested`       | `--reason`                                         | `reason` ∈ `blocked-user-input`, `question`, `permission`  |
| `escalation_requested` | `--from-route`, `--to-route`, `--evidence`         | free-form (all three required and non-empty)               |
| `error`                | `--severity`, `--category`, `--message`            | `severity` ∈ `P0`, `P1`, `P2`, `P3`; `category`/`message` free-form |
| `human_intervention`   | `--kind`                                           | `kind` ∈ `takeover`, `supersede`, `manual-fix`, `drain`    |

The typed fields (`reason`, `from_route`, `to_route`, `evidence`, `severity`,
`category`, `kind`) are payload-only and never become path segments. Events stay
append-only and reuse the same write path as every other `record-event` call.
These four types plus their fields are the schema downstream consumers (the event
harvester and the agent-workflows companion) read; treat this table as the
reference.

`heartbeat` upserts `heartbeats/<agent-id>.json`. `status` renders coordination
state in text or JSON. Full `status` renders compact claims, heartbeats, batch
lanes, lane dependencies, blocked-on refs, and recent events for broad audits.
Scoped status is the preferred batch-workflow path:

- `status --repo OWNER/REPO --target ISSUE_OR_PR` reads only
  `claims/<owner>/<repo>/<issue-or-pr>.json` and that claim holder's heartbeat
  when a holder exists.
- `status --batch-id ID` reads only `batches/<id>.json`, `events/<id>/`,
  lane-owner heartbeats, and dependency batch files plus referenced lane-owner
  heartbeats needed to compute `blocked_on`.

Scoped JSON payloads include `scope` and `degraded` fields. A scoped command can
show `degraded` notes for intentionally omitted unrelated state, such as claims
not checked in batch scope; that is different from exit 2. Exit 2 means the
coordination backend result is `UNKNOWN` for that command. Text status renders the
same degraded notes as a footer when rows are present. In large backends, prefer
target or batch scoped status for React on Rails batch lanes and treat a timed
out full coordination read as degraded/`UNKNOWN` rather than guessing.
Unscoped `status` excludes `archive/` by default. Pass `--include-archived` for
an explicit archive inventory; scoped status remains hot-state-only so target
and batch dependency checks never turn into an all-archive scan.

### batch-audit telemetry-completeness gate

`batch-audit --batch-id ID` reports, per registered lane, which expected
lifecycle events are missing, so a batch-closeout workflow can fail-closed on an
incomplete event trail. It is read-only and, like `status`, defaults to the local
status state root. It reads the registered batch manifest for its lanes and the
batch's events under `events/<batch-id>/`, attributing each event to a lane by
this rule: an **explicit event `lane` matching the lane name is always trusted**
(lane names are unique); a **`target`** match attributes only when the target is
**unique among the batch's lanes** (maps to exactly one lane); and the **owner
(`agent_id`)** fallback attributes only when the owner is unique among the batch's
lanes **and the event's target belongs to that lane** (or the event carries no
target). This is what links the auto-emitted `claim.acquired`/`claim.released`
events (which carry `agent_id` and `target` but no `lane` field) to their lane —
while a unique owner doing unrelated work on a different target under the same
batch-id does not complete the lane. `register-batch` enforces unique lane *names*
but not unique targets or owners, so when two lanes share a target or an owner that
shared key is ambiguous and is not used on its own for attribution; a lane whose
only keys are ambiguous and was never touched by a lane-name-tagged event correctly
stays incomplete rather than false-completing. Empty-string targets are ignored
(never an attribution key). When the batch manifest
declares a `repo`, only events whose `repo` matches it are considered at all (lanes
carry no per-lane repo); a batch id reused across repos with colliding target numbers
therefore cannot let an event recorded under a different `--repo` complete a lane. A
batch that declares no repo applies no repo gate.

A lane is **telemetry-complete** when it has both:

- at least one `claim.acquired` event, and
- a terminal signal — either a `claim.released` event or a `lane_closed` event.

A lane missing either signal is reported incomplete with the specific missing
signals (`claim.acquired`, `terminal`); a lane with no events at all is incomplete
with both missing. A malformed (non-object) lane entry in the manifest is reported
incomplete (never assumed complete). The batch verdict is `complete` only when
every registered lane is complete. A batch that registers no lanes (an empty or
missing `lanes` array, only reachable via hand-edited/legacy state since
`register-batch` rejects it) is reported UNKNOWN (exit 2), never a vacuous
`complete`. Text output lists each lane; `--json` enumerates per-lane
`{ name, owner, targets, event_count, missing, complete, malformed }` (every lane
entry carries the same keys — `malformed` is `false` for a normal lane and `true`
for a non-object manifest entry) plus the overall `verdict`.

Exit codes let closeout gate on the result:

| Exit | Verdict      | Meaning                                                                 |
| ---- | ------------ | ----------------------------------------------------------------------- |
| 0    | `complete`   | Every registered lane has an acquire event and a terminal signal.       |
| 1    | `incomplete` | At least one lane is missing a signal; closeout should fail-closed.      |
| 2    | `unknown`    | Coordination state is UNKNOWN — the batch id is unregistered, invalid/unsafe, a non-object batch record, a batch registering no lanes, an event trail only partially visible to a scoped token (filtered listing), or the batch/events are unreadable. A malformed id returns `unknown` (exit 2), never `incomplete` (exit 1). Never reported as a false `complete`. |

### Host-limit contract foundation

The published
[`schema/state/v1/host-limit.schema.json`](schema/state/v1/host-limit.schema.json)
defines a shared usage-limit record keyed by
`(workspace, machine, quota_host, scope)`. `quota_host` is a canonical quota-pool
identifier deliberately distinct from existing lane
`host` app/wrapper metadata; runtime mapping between them remains `UNKNOWN`. The
contract includes active and explicitly cleared states, known or unknown reset
times, and an optional `host_limits` status projection from which
consumers may derive `blocked-on-limit` for lanes carrying a matching explicit
`quota_host`. Positive, negative, procedural, and two-lane replay fixtures live
under [`schema/state/v1/fixtures/`](schema/state/v1/fixtures/).

This is a schema-only foundation. The CLI and Worker do not yet report, persist,
clear, or project these records, and provider message/probe facts remain
`UNKNOWN`. See [ADR 0007](docs/adr/0007-host-limit-state-contract.md) for
canonical quota-host, reset, clear, workspace-key, composite uniqueness, and
non-goal semantics.

### Capacity reservation contract foundation

The schema-first reservation contract lives under
[`schema/state/v1/capacity-reservation/`](schema/state/v1/capacity-reservation/).
It makes four protocol-plane inputs authoritative: numeric capacity profiles,
enabled inboxes bound to those profiles, persisted lane occupancy (including
blocked lanes without live heartbeats), and short-lived per-lane reservation
holds. Product-plane planning, ranking, scheduling, and approval UI remain
separate consumers of this protocol state.

Capacity is the unique union of `occupied`/`blocked` lane refs and active
reserved lane refs, so reservation-to-launch overlap counts once. Creation is
all-or-nothing and fails closed when any capacity, inbox, occupancy, or
reservation input is missing, malformed, disabled, cross-workspace, or
mismatched. Host-limit records remain a separate eligibility gate. Reservation
holds use the authenticated machine plus planner owner/instance tuple, expire on
server time with `expires_at` derived exactly from `created_at + ttl_seconds`,
and move monotonically from `active` to `consumed`, `released`, or `expired`.

The replay fixtures cover final-slot contention, idempotent retry, payload
conflict, workspace/profile matching, TTL boundaries, owner enforcement, and
partial consume/release. Runtime CLI/Worker operations are intentionally not
implemented here; a later additive CLI uses `RESERVATION_REFUSED` exit code 4
rather than overloading `CLAIM_REFUSED`. See
[ADR 0008](docs/adr/0008-capacity-reservation-state-contract.md).

### Usage record contract foundation

The published
[`schema/state/v1/usage/usage-record.schema.json`](schema/state/v1/usage/usage-record.schema.json)
defines a per-model token and estimated-cost record keyed by
`(workspace, repo, batch_id, lane_name, agent_id, target, model)`. One record
per model lets consumers aggregate tokens-by-model and per-batch token/cost
tiles. `input_tokens`, `output_tokens`, and `cost` are optional metrics: an
unknown value is sent as `null` or the em dash `"—"` and is never omitted or
emitted as a fabricated zero, so the schema rejects both a dropped metric key
and any other string. v1 `cost` is USD only, so aggregation never combines
currencies. An optional `usage` status projection embeds records into existing
status documents; consumers exclude unknown metrics from sums and keep an
all-unknown model or batch aggregate unknown rather than zero. Positive,
negative, procedural, and aggregation replay fixtures live under
[`schema/state/v1/usage/fixtures/`](schema/state/v1/usage/fixtures/).

This is a schema-only foundation. The CLI and Worker do not yet report, persist,
or project these records, and provider token accounting and pricing remain
`UNKNOWN`. Absent usage keeps the dashboard's `—` degrade. See
[ADR 0009](docs/adr/0009-usage-record-state-contract.md) for logical-key,
optional-metric discipline, storage-key encoding, and non-goal semantics.

### Lane route contract foundation

The published
[`schema/state/v1/route/route.schema.json`](schema/state/v1/route/route.schema.json)
defines a lane's bound model + reasoning effort (the "route"), emitted additively
on a claim, heartbeat, or lane-manifest record. A route is either the compact
`model/effort` string (for example `gpt-5.6-sol/xhigh`) or the equivalent
`{ model, effort }` object; both canonicalize to the same chip. Route is optional
and the only way to signal no route is to omit the property — it is never `null`
— so the dashboard degrades an absent route to a hidden/`—` chip. Positive,
negative, and chip-rendering fixtures live under
[`schema/state/v1/route/fixtures/`](schema/state/v1/route/fixtures/).

This is a schema-only foundation. The CLI and Worker do not yet emit, detect, or
project routes. Route rides on the identity of its host record and declares no
key of its own. See [ADR 0010](docs/adr/0010-route-state-contract.md).

### Batch merge-authority contract foundation

The published
[`schema/state/v1/merge-authority/merge-authority.schema.json`](schema/state/v1/merge-authority/merge-authority.schema.json)
persists a batch's declared merge authority additively on the batch manifest as
the canonical short enum `none | ask | auto`. The pr-batch launch vocabulary maps
to these before persistence (`auto_merge_when_gates_pass` → `auto`), so the
dashboard reads one short value. It is optional and signaled absent by omission
only — never `null` — so a legacy batch degrades to an em-dash Merge auth field,
distinct from an explicit `none`. Positive, negative, and drawer fixtures live
under
[`schema/state/v1/merge-authority/fixtures/`](schema/state/v1/merge-authority/fixtures/).

This is a schema-only foundation. The CLI and Worker do not yet capture the
launch declaration into batch state. See
[ADR 0011](docs/adr/0011-merge-authority-state-contract.md).

### Batch completion-report contract foundation

The published
[`schema/state/v1/batch-completion/batch-completion.schema.json`](schema/state/v1/batch-completion/batch-completion.schema.json)
persists a completed batch's `audit` (verdict + free-form author that folds
version and timestamp), `completion` report (`state`, `receipts`, `baseline`,
per-lane `outcomes`, and optional `usage`/`tokensTotal`/`cost`/`duration`), and
`finalReport`, keyed by `(workspace, batch_id)`, so the dashboard drawer renders the audit
chip, completion table, and final report instead of a degrade note. The
dashboard-rendered payload follows the dashboard report contract verbatim
(camelCase field names such as `tokensTotal`), while the record envelope keeps
snake_case. Optional metrics send `null`/`"—"` and are never omitted or
fabricated; archive-ready requires `state.live`, `audit`, and `receipts`.
Positive, negative, and drawer-render fixtures live under
[`schema/state/v1/batch-completion/fixtures/`](schema/state/v1/batch-completion/fixtures/).

This is a schema-only foundation. The CLI and Worker do not yet capture batch
handoffs into this record. See
[ADR 0012](docs/adr/0012-batch-completion-state-contract.md).

### Batch blocker contract foundation

The published
[`schema/state/v1/batch-blocker/batch-blocker.schema.json`](schema/state/v1/batch-blocker/batch-blocker.schema.json)
persists a structured blocker on a batch, keyed by `(workspace, batch_id)`, when
a supervisor blocks on operator authority: a `message`, a non-empty `decisions`
list, and an optional `recommendedReply`. `recommendedReply` is signaled absent
by omission only — never `null` — so the dashboard renders the Blocker panel
instead of reconstructing decisions from lane `blockedOn` dependencies. Positive,
negative, and panel-render fixtures live under
[`schema/state/v1/batch-blocker/fixtures/`](schema/state/v1/batch-blocker/fixtures/).

This is a schema-only foundation. The CLI and Worker do not yet persist a
structured blocker. A batch with no blocker keeps the `blockedOn`-derived
fallback. See [ADR 0013](docs/adr/0013-batch-blocker-state-contract.md).

`gc` applies one retention plan to local, GitHub, and HTTP stores. Exactly one
mode is required: `--dry-run` prints proposed actions without writing, while
`--execute` copies eligible records into `archive/` with compare-and-swap
protection and only then removes their hot source. Terminal lane/target events are
compacted into an immutable archive envelope before their source events are
removed. Events are grouped by batch, lane, repository, and target. A lane-less
event joins the sole valid terminal lane for the same batch/repository/target;
when zero or multiple terminal lanes exist it remains in the explicit legacy
group, so one lane's marker cannot sweep a sibling lane. A generation is deferred until every current
source event has independently passed its hot window. Each envelope path
includes a deterministic digest of lane/provenance identity, source paths, and
recursively key-sorted JSON content, so an identical retry reuses the same
destination while changed content at a stable path creates a new generation
without rewriting the first. The envelope lists every consumed
source path but retains only the first
event, last event, every valid terminal event, and actual phase transitions;
repeated same-phase renewals are intentionally dropped.
If a multi-source delete stops after some hot events are removed, retry can
leave the immutable archive envelope as a safe expiring duplicate;
copy-before-delete still guarantees retained history is not lost.
Likewise, ordinary source mutation after the archive write but before the CAS
delete can leave a stale expiring envelope, but CAS prevents deletion of the
new live payload.
Expired archive envelopes are deleted with the same compare-and-swap guard.

| Record state | Hot retention | Archive retention | Result |
| --- | ---: | ---: | --- |
| Released/terminal claim | 7 days | 30 days | Archive, then delete |
| Dead or terminal heartbeat | 7 days | 30 days | Archive, then delete |
| Completed batch | 7 days | 30 days | Archive, then delete |
| Events for a terminal target | 7 days | 30 days | Compact, then delete |
| Eligible claim/heartbeat/batch with `synthetic: true` | 1 day | 30 days | Aggressive archive, then delete |
| Fully synthetic orphan event generation | 1 day per event | 30 days | Compact, then delete |

`--hot-days`, `--archive-days`, and `--synthetic-hot-days` override those
defaults. Archive retention starts at `archived_at`, so the default lifecycle
is 7 hot days followed by 30 archive days. Producers mark non-production state
with `--synthetic --synthetic-kind simulation|smoke`; batch manifests may carry
the same fields. The marker shortens retention only after normal family
eligibility: active claims, live heartbeats, and incomplete batches remain hot.
This protects scripted workers that claim once and refresh only their heartbeat.
Synthetic events without a valid terminal marker compact as an orphan
generation only after every event independently passes the synthetic window;
missing repository or target metadata uses the batch/lane/available-provenance
identity rather than blocking cleanup. Metadata-less legacy events remain in
their own absent-lane group, and non-synthetic orphan events remain untouched.
Run `ruby sim/bin/graveyard` for a deterministic dry-run,
execute, compaction, and idempotent replay check.
Repeat `--prefix claims|heartbeats|batches|events` to restrict hot-family scans;
without it GC scans all four families. Archive expiry is always scanned. For
example, `agent-coord gc --execute --prefix claims` works with a
least-privileged token that can read the selected claims subtree plus its
archive mirror and can write/delete both. Forbidden selected prefixes remain an
operational error; GC never silently widens or skips requested scope.
Scoped HTTP tokens used for GC need read and write coverage for each selected
hot prefix and `archive`; use `--all-state` only for a trusted operator machine.
`release` marks a claim released while preserving the record for auditability.
Only the recorded holder can release or restamp metadata on an existing claim;
another agent should claim the target after release instead of re-releasing the
old holder's record. For planned ownership moves, include `--handoff-to` and
`--handoff-note` on the original release, then have the next worker claim the
same repo/target and continue on the recorded branch/PR.
`version` prints the CLI contract version. `config show --json` prints runtime
defaults and machine-readable exit codes. Default `doctor` verifies the current
backend without writing state or parsing every record; `doctor --deep` adds full
JSON validation. For HTTP tokens whose read scope does not overlap `claims`, use
`doctor --doctor-prefix <read-prefix>` to verify that scoped read path.
`bootstrap` installs the `agent-coord` command used by public
workflow docs.

## Legacy / Non-Stack CLI Contract And Exit Codes

Use `agent-coord version --json` and `agent-coord config show --json` as the
stable contract for public workflow docs. Public repos should avoid copying
private implementation defaults when they can point agents at these commands.

The following exit code contract applies to legacy and non-stack commands. The
`doctor --stack-json` component contract and its exit codes are documented in
the doctor section above.

| Exit | Meaning                                  | Agent behavior                                                                 |
| ---- | ---------------------------------------- | ------------------------------------------------------------------------------ |
| 0    | Command succeeded                         | Use the returned state.                                                        |
| 1    | Usage error                               | Fix the command invocation before proceeding.                                  |
| 2    | Operational failure                       | Report coordination state as `UNKNOWN`; use advisory fallback when safe.       |
| 3    | `CLAIM_REFUSED` by live/stale/active hold | Hard stop for machine agents; report holder/liveness instead of competing.     |
| 4    | Reserved future `RESERVATION_REFUSED`     | Stop admission without treating capacity contention as an operational failure. |

A refused claim is intentionally different from a bootstrap/auth/network
failure. A machine agent may not override exit 3 on its own. Exit 2 means the
backend could not be trusted for that command, including storage-level compare
and-swap contention and a refused split-brain write (a consumer env file
configures `AGENT_COORD_API_URL` while the CLI fell back to the implicit local
root; `doctor` reports `status: split_brain` for the same condition);
dependency-sensitive lanes should stop with `UNKNOWN` until
the coordinator restores backend access. Exit 4 is reserved by ADR 0008 but is
not emitted or reported by `config show --json` until the separately sequenced
capacity-reservation runtime commands exist. This additive reservation
supersedes the 0-3 freeze only for that future boundary; the archived Backend v2
Phase 1 plan remains historical guidance for its completed phase.

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
AGENT_COORD_MACHINE_ID=<machine-id, e.g. m5>
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
`AGENT_COORD_API_URL`, `AGENT_COORD_API_TOKEN`, and `AGENT_COORD_MACHINE_ID`
from that local file instead of storing values in the repository. Background
services read only this env file — a machine id exported solely in a shell
profile does not reach them, so keep it in the env file for heartbeat
attribution.

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
`AGENT_COORD_API_URL`, `AGENT_COORD_API_TOKEN`, and `AGENT_COORD_MACHINE_ID`.

## State Layout

Runtime state lives in these directories:

```text
claims/<owner>/<repo>/<issue-or-pr>.json
heartbeats/<agent-id>.json
batches/<batch-id>.json
events/<batch-id>/<event-id>.json
archive/claims/<owner>/<repo>/<issue-or-pr>.json
archive/heartbeats/<agent-id>.json
archive/batches/<batch-id>.json
archive/events/<batch-id>/<event-or-compaction-id>.json
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
  "machine_id": "m5",
  "session_id": "019a2f6c-codex-thread",
  "session_source": "codex_thread_id",
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

Allowed claim `status` values are `active` and `released`. A released claim may
also carry terminal `done`, `abandoned`, or `superseded` semantics. For lane
status, protocol-declared terminal state wins over heartbeat or GitHub-derived
state; consumers derive from GitHub only when terminal protocol state is absent.
Coordinators should treat a claim holder with a `dead` heartbeat as recoverable
even if the claim `expires_at` timestamp is still in the future. `expires_at`
remains useful for audit and as the fallback when the heartbeat is missing or
invalid.

Optional lane metadata fields on claims are `thread_handle`, `chat_handle`,
`host`, `machine_id`, `session_id`, `session_source`, `pr_url`,
`dashboard_url`, `operator`, `phase`, `generation`, and `instance_id`.
`release` preserves the existing claim record and the recorded holder may
update the same metadata fields for terminal states, such as adding a final
`pr_url` or `phase`. `machine_id`, `session_id`, and `session_source` come from
the machine/session identity environment described in
[Machine and session identity](#machine-and-session-identity); a write without
that environment preserves the last recorded attribution, and a write that
declares a different machine without a session clears the stale session fields.

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
  "machine_id": "m5",
  "session_id": "019a2f6c-codex-thread",
  "session_source": "codex_thread_id",
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
`host`, `machine_id`, `session_id`, `session_source`, `pr_url`,
`dashboard_url`, `operator`, `phase`, `generation`, `instance_id`, and
`status_raw`. Status readers should treat missing metadata as `UNKNOWN` rather
than inferring it from branch names or handoff text. `machine_id`,
`session_id`, and `session_source` come from the machine/session identity
environment; renewals without that environment preserve the last recorded
attribution, and renewals declaring a different machine without a session
clear the stale session fields.

### Heartbeat status vocabulary

Heartbeat and ordinary-event `status` values are a canonical enum, normalized
by the CLI at write time. Multi-word values are snake_case. The machine-
readable vocabulary, including the alias map, is published by
`agent-coord config show --json` under `heartbeat_status_vocabulary`.

Working statuses (the lane owner is active or the lane needs attention):

| Status                        | Meaning                                             |
| ----------------------------- | --------------------------------------------------- |
| `in_progress`                 | Owner is actively working the lane                  |
| `blocked`                     | Blocked on an unmet lane dependency                 |
| `blocked_user_input`          | Blocked on an operator or user decision             |
| `waiting_on_checks_or_review` | PR up; waiting on external checks or review         |
| `external_gate_failing`       | An external gate (CI, review bot) is failing        |
| `no_pr_evidence`              | Closeout audit found no PR evidence; needs triage   |
| `failed`                      | Work attempt failed; lane needs attention           |

Terminal statuses (the owner is finished and will not renew the heartbeat):

| Status                      | Meaning                                          |
| --------------------------- | ------------------------------------------------ |
| `done`                      | Work completed                                   |
| `merged`                    | PR merged                                        |
| `ready`                     | Work complete and ready for pickup or merge      |
| `ready_gates_clean`         | PR ready with gates green, awaiting merge        |
| `ready_no_merge_authority`  | Work complete; worker lacks merge authority      |
| `abandoned`                 | Lane abandoned without completing                |
| `superseded`                | Lane superseded by other work                    |

Write-time normalization first folds case and hyphens (`Done`,
`waiting-on-checks-or-review`, and `In-Progress` fold to their snake_case
forms), then applies the known-alias map:

| Alias                                                            | Canonical     |
| ---------------------------------------------------------------- | ------------- |
| `complete`, `completed`                                           | `done`        |
| `ready_to_merge`, `ready_handoff`, `ready_for_coordinator`        | `ready`       |
| `in_process`, `claimed`, `implementing`, `validating`, `pushing`  | `in_progress` |

`released` is deliberately not an alias: a released heartbeat can mean a claim
handoff rather than completion, so it takes the unknown-value path below and
never satisfies dependencies. When coercion changes the caller's value, the
original spelling is preserved
in `status_raw`. Values that resolve to neither the vocabulary nor the alias
map are preserved verbatim, copied to `status_raw`, and reported with a
`warning:` line on stderr; the exit code of an otherwise-successful write does
not change. `status --json` projects `status_raw` on heartbeats and events. A
record whose `status` equals its `status_raw` was written with unrecognized
vocabulary.

Normalization applies where the CLI writes caller-supplied status values: the
`heartbeat` command and ordinary `record-event` statuses. Claim `status`
(`active`/`released`), lane-closure `terminal` reasons, and the `released`
claim-status snapshot on `claim.released` events are separate closed vocabularies
written by the CLI itself and pass through unchanged. Rows written by older
CLIs are normalized only when rewritten: dependency gating still accepts the
legacy `complete`/`completed` synonyms, and `gc` continues to reclaim legacy
non-canonical rows through dead-heartbeat classification while classifying
canonical terminal statuses as `terminal_heartbeat`.

Claims and heartbeats may carry `synthetic: true` and a `synthetic_kind` such as
`simulation` or `smoke`. These markers are protocol metadata: they let `gc`
apply the shorter synthetic hot-retention window without guessing from names.

Archive envelopes have a shared 1 MiB serialized-data cap in the CLI and HTTP
Worker. Dry-run and execute identically preflight every planned
archive/compaction envelope; execute performs no writes if any would exceed the
cap. Split or reduce the source history before retrying. A malformed or
forward-incompatible record encountered while evaluating an otherwise eligible
retention action intentionally fails the whole plan with a path-specific
operational error; unknown or non-eligible records remain untouched. Repair the
record or upgrade the consumer, then retry. Active HTTP records retain their
separate 256 KiB cap.

## Archive Schema

Archive paths mirror the hot record grammar below `archive/`. A single-record
envelope retains `source_path` and the original `data`; terminal event
compaction uses `source_paths` as the complete set of consumed inputs and
`records` as the compacted first/last/phase-transition history; the arrays are
not positional and renewal paths may have no retained record. Both carry
`archived_at`, `delete_after`, `reason`, and the synthetic marker. The published
contract and fixture are
[`contracts/archive-record-schema-v1.json`](contracts/archive-record-schema-v1.json)
and
[`contracts/fixtures/v1/`](contracts/fixtures/v1/).
Compaction archive filenames include both a canonical lane/provenance identity
digest and a path-plus-content source-generation digest. Multiple immutable
envelopes for one identity are valid successive generations, not a conflict or
an in-place append protocol.

## Event Schema

```json
{
  "schema_version": 1,
  "event_id": "20260708T235500.123456Z-deadbeef",
  "batch_id": "batch-2026-06-13",
  "type": "phase",
  "lane": "docs",
  "agent_id": "worker-3972",
  "repo": "shakacode/react_on_rails",
  "target": "3972",
  "branch": "jg-codex/3972-docs",
  "thread_handle": "thread-docs",
  "host": "codex",
  "operator": "justin",
  "phase": "validating",
  "message": "running tests",
  "at": "2026-06-13T00:42:00Z"
}
```

Required fields: `schema_version`, `event_id`, `batch_id`, `type`, and `at`.
Events also carry the optional `machine_id`, `session_id`, and
`session_source` attribution fields when the machine/session identity
environment is set, and `lane_closed` events resolve `closed_by.machine` from
`AGENT_COORD_MACHINE_ID` before falling back to `host`.
Ordinary events retain schema version 1. The explicitly versioned
`lane_closed` event uses schema version 2 and follows the published contract;
`version --json` advertises both `schema_version` and
`lane_closed_schema_version` so producers do not mislabel unrelated records.
Lane events should include `lane` and `agent_id` when available. Lane names
follow the same rules as registered batch lanes: non-empty and no `:`
characters, because dependency refs split on the last colon. An ordinary
event's optional `status` uses the
[heartbeat status vocabulary](#heartbeat-status-vocabulary) and is normalized
the same way at write time, with the caller's original spelling in
`status_raw` when coercion changed it. `claim.released` events record the
released claim's `status` snapshot (`released`) verbatim; that value is
claim-status vocabulary, not a heartbeat status. Event ids are
time-sortable and unique per write for ordinary append-only events. A
`lane_closed` ID is instead stable per batch/lane and begins with
`lane_closed-`; it is not a chronology key. Consumers should order mixed event
families by `at` (using path only as a deterministic tie-breaker), and deduplicate
terminal closeout by its batch/lane reservation path rather than by arrival
order.

The current HTTP backend stores events in the same JSON state API as claims,
heartbeats, and batches, so `events/<batch-id>` is intended for low-volume phase
transitions and audit breadcrumbs, not high-frequency telemetry. Keep event
volume bounded per batch until the relational `/v1/events` endpoint in
[backend-design.md](docs/backend-design.md) replaces the interim JSON store.
The interim Worker state listing is resumable: `GET /v1/state?prefix=...` keeps
the historical full-snapshot response, while callers may pass `limit` and then
follow `next_cursor` with the same prefix to read additional pages. Prune or
export released claims, expired heartbeats, and old batch/event records before
prefix snapshots become expensive.

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
`register-batch` writes `schema_version`, `registered_at`, and `updated_at`. Use
`--launch-prompt PATH|-` to attach the exact coordination prompt without editing
the manifest JSON.

Each lane should include `name`, `owner`, and `targets`. `owner` is the stable
agent id used by `heartbeat`, so `status` can attach the lane's latest heartbeat
status and liveness. Lane names must not contain `:`; batch ids may contain `:`.
`depends_on` is optional and accepts a string or array of lane refs in the form
`<batch-id>:<lane-name>`, split at the last colon.

Top-level batch metadata such as `repo`, `objective`, `instructions`, `launch_prompt`,
`operator`, `dashboard_url`, and lane metadata such as `thread_handle`, `chat_handle`,
`host`, `pr_url`, `dashboard_url`, `operator`, and `phase` are preserved and
included in JSON status output. A dependency is considered met when the
referenced lane owner's heartbeat reports a dependency-satisfying terminal
status: `done`, `merged`, `ready`, `ready_gates_clean`, or
`ready_no_merge_authority` from the
[heartbeat status vocabulary](#heartbeat-status-vocabulary), plus the legacy
`complete`/`completed` synonyms still stored in rows written by older CLIs.
A stored legacy `released` row stays excluded: it can mean a handoff release
rather than completion, so it does not unblock dependents. New `released`
writes are equally non-dependency-satisfying — they are not aliased, so the
CLI warns and preserves them verbatim with a `status_raw` copy.
Terminal `abandoned` and `superseded` heartbeats end a lane without completing
it and do not unblock dependents. A released claim is preserved for
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
3. Worker refreshes a heartbeat during active work and records phase events for
   milestones that should remain visible after later heartbeats overwrite state.
4. Coordinator uses targeted `status --repo ... --target ...` or
   `status --batch-id ...` for lane decisions, and full `status` only for broad
   audits where an all-state scan is acceptable.
5. Worker releases the claim or lets the lease expire if the session is lost.

Keep leases short enough that abandoned work is recoverable, usually 2-4 hours
for active batch claims and 15 minutes for heartbeats.
