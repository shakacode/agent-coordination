# Changelog

All notable changes to Agent Coordination will be documented in this file.
The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
when releases begin.

## [Unreleased]

### Added

- An `agent-coord log` command that renders the per-work-item custody trail the
  event store already records, so an operator can ask where the work on one issue
  or PR stands without reading the full coordination dump (issue #129).
  `agent-coord log OWNER/REPO#TARGET` prints one line per event, oldest first,
  with columns for timestamp, machine, host family, work item, event type, phase,
  agent, and detail. Where a work item sits now is the last line; a move is a
  change in the machine, host, or agent column; when it was last worked on is the
  timestamp. The command derives no verdict beyond ordering events by time.
  Filters: `--since` (a `3d`/`12h`/`30m` duration or an ISO8601 timestamp),
  `--machine`, `--host`, `--type`, and `--limit`. Output: aligned text by default,
  `--format tsv` for a tab-separated record that also carries the unnormalized
  host and the event id, or `--json`. `--sync` appends unseen rows to
  `<state-root>/log.tsv` so plain `grep` answers the same questions offline, and
  because it only ever appends, that local trail survives `gc` pruning the hot
  events behind it. Simulation and smoke records are excluded unless
  `--include-synthetic` is passed. The many recorded spellings of `host` (`codex`,
  `codex-subagent`, `codex-desktop`, `codex-collaboration@its`, `claude-code`)
  normalize onto the `codex`/`claude` families already used by
  `lib/agent_coordination/host_adapters.rb`, with the raw value preserved in the
  tsv column beside it. Events recorded before machine stamping report `?` rather
  than an inferred machine. `log` is read-only: it never writes coordination
  state, and it is not a split-brain write command, so it keeps the existing
  advisory that warns when local state is being read instead of the fleet.
  Work-item, machine, host, and type matching is case-insensitive, because the
  event store has recorded the same repository under more than one casing and an
  exact match would split one work item's history into two partial answers. When
  a work item has no events at all, any claim record for it is reported instead
  of a bare "no events", so a claim written before lifecycle auto-emit does not
  read as absent custody. `--sync` reads and writes the mirror as UTF-8 rather
  than trusting the locale; under a non-UTF-8 locale a row carrying a non-ASCII
  character would otherwise never match the line regenerated from state and would
  re-append on every sync. Events are ordered on a parsed instant rather than on
  the rendered string, so timestamps carrying an offset or fractional seconds
  order correctly and an undated legacy event sorts first rather than last
  (sorting it last would have made it read as the current state); `--since` never
  includes undated events. `--limit` rejects a negative value and cannot be
  combined with `--sync`, which would otherwise mirror only the most recent slice
  and lose the rest once `gc` pruned the events behind it. Every tsv field is
  scrubbed of tabs and newlines, not just `detail`, so agent-supplied text cannot
  invent a column or split a row. Under `--format tsv` the empty-result note goes
  to stderr rather than into the data stream. When a scoped token returns a
  partial event listing, `log` warns that the trail may be incomplete instead of
  presenting it as whole, and a scoped or unsupported listing degrades to an empty
  trail with a warning rather than crashing a read-only query. `--sync` refuses to
  write a mirror from an incomplete listing, since a partial mirror would later
  read as complete. A claims lookup
  that cannot be read warns too, so "this token cannot read claims" no longer
  prints identically to "this work item has no claim". An explicitly selected
  backend is never replaced by the local status root. Options may precede the
  positional work item, so `log --json OWNER/REPO#1` parses. `--sync` mirrors the
  complete trail and rejects any narrowing option, because appending a narrow sync
  and then a broader one would place older events after newer ones and the file's
  last line would stop being the current state. The mirror is deduplicated and
  appended under one exclusive lock, so two writers cannot both decide the same
  rows are new. Text columns are scrubbed of tabs and newlines like the tsv ones,
  so agent-supplied text cannot split one printed event across two lines. A
  filtered claims listing warns as well, so a hidden claim does not read as an
  absent one, and when a repository is recorded under two casings the newest of
  the matching claims is the one reported. The mirror is kept in timestamp order
  rather than appended blindly, since a later sync can still discover an older
  event and the file's last line has to stay the current state. `--sync` honors
  `--json`. The claim note is built from claim fields directly rather than through
  the event projection, which had printed a claim whose status is `active` as
  `phase active`, and it is scrubbed like every other output path. Instants are
  compared exactly rather than through a float. The mirror is replaced
  atomically -- written to a temporary file, flushed, then renamed -- because
  after `gc` prunes the backend it can be the only remaining copy of a row, and
  a crash partway through an in-place rewrite would destroy it; the exclusive
  lock moved to a `log.tsv.lock` sidecar so it survives that replacement.
  `--include-synthetic` is allowed with `--sync`, since it widens the mirror
  rather than narrowing it, and rejecting it left simulation history with no way
  to be preserved before `gc` pruned it. The `--repo OWNER/REPO --target
  ISSUE_OR_PR` options that every command advertises now scope the trail as an
  alternate spelling of the positional, rather than being accepted and ignored
  while the whole feed was printed; giving the work item both ways is an error.
  `--format` is validated on the `--sync` path too. The mirror breaks
  same-timestamp ties on event id exactly as the command does, so a grep of the
  file and a `log` invocation cannot disagree about what happened last, and a
  mirror an operator restricted keeps its mode across replacement. `--host`
  accepts any recorded spelling rather than only the normalized family name, so
  `--host claude-code` matches the claude family instead of silently matching
  nothing. Zero-padded durations such as `--since 08h` are read as decimal;
  `Kernel#Integer` had treated the leading zero as octal, raising an uncaught
  error for `08`/`09` and reading `010d` as eight days. Synthetic rows carry
  `synthetic` and `synthetic_kind` columns in tsv and JSON and a `[synthetic]`
  marker in text, so simulation history merged into the mirror by
  `--sync --include-synthetic` cannot later be mistaken for real work. Rendered
  text and tsv strip C0 control characters and DEL as well as tabs and line
  endings, so an ANSI escape recorded in an event message cannot clear or rewrite
  the trail on the reader's terminal; JSON is left alone because its encoder
  escapes these already. Publishing the mirror fsyncs the parent directory after
  the rename, the way `LocalStore` already does, since a rename is not durable
  until the directory entry reaches stable storage, and the temporary file it
  renames from is created exclusively under an unpredictable name so a symlink
  planted at that path cannot be followed; a mirror that does not yet exist
  follows the operator's umask, while an existing file's mode is reasserted
  across replacement. Filesystem faults while writing the
  mirror are reported as operational errors rather than a Ruby backtrace. The
  control scrub covers C1 controls as well as C0 and DEL, since terminals that
  decode C1 act on `U+009B` the way they act on `ESC[`. A positive `--limit` no
  longer suppresses the claim fallback, because it removes nothing from a trail
  that was already empty. Under `--json` the claim is a structured object rather
  than a preformatted sentence. The `--sync` narrowing error names real flags
  instead of a `--work-item` option that does not exist. A claim is reported
  whenever it is newer than the last event, not only when there are no events at
  all: `claim` permits omitting `--batch-id` and no lifecycle event is emitted
  without a batch, so a work item can carry stale events and a live claim at the
  same time, and answering with the last event would have named the wrong place.
  A claim whose lease has run out is reported as `lease elapsed <time>` in text
  and carries `lease_elapsed`/`expires_at` in JSON rather than being presented as
  current custody; the fleet holds many claims left active with a lease long past,
  and recency alone does not make one live. The elapsed lease is reported as a
  fact rather than as expired custody, because whether custody truly ended also
  depends on the holder's heartbeat, and deciding that here would be the state
  inference this command exists to avoid. A synthetic claim is marked the way synthetic
  events are.
- An `AGENT_COORD_LOCAL` environment opt-in that explicitly selects the implicit
  local backend. It accepts `1`, `true`, or `yes` (case-insensitive); any other
  value, including empty and `0`, is not an opt-in. Setting it both satisfies the
  new split-brain write hard stop and silences the existing split-brain advisory
  warning on read commands, so a deliberate single-machine operator can keep a
  consumer env file on disk without unsourcing it (issue #97). No gem has been
  published, so no migration is required.
- A typed operational-signal event vocabulary for `record-event` plus a
  `batch-audit` closeout completeness gate. `record-event --type` now recognizes
  four typed names whose required fields are validated at write time (rejecting a
  missing field or out-of-set value with a clear error and a non-zero exit):
  `help_requested` (`--reason` in blocked-user-input|question|permission),
  `escalation_requested` (`--from-route`, `--to-route`, `--evidence`), `error`
  (`--severity` in P0|P1|P2|P3, `--category`, `--message`), and
  `human_intervention` (`--kind` in takeover|supersede|manual-fix|drain). The
  typed fields are additive payload-only fields, projected present-only into
  `status --batch-id --json`; any other `--type` value stays allowed and
  unvalidated, and events remain append-only on the existing write path. The new
  `agent-coord batch-audit --batch-id ID` command reports, per registered lane,
  the missing lifecycle events (text or `--json`): a lane is telemetry-complete
  with both a `claim.acquired` event and a terminal signal (`claim.released` OR
  `lane_closed`), and the command exits `0` when every lane is complete, `1` when
  gaps are found so closeout can fail-closed, and `2` when coordination state is
  UNKNOWN (unregistered or unreadable batch). No gem has been published, so no
  migration is required.
- Auto-emitted claim-lifecycle events so a claim's acquire, phase transitions,
  and release leave a queryable trail under `events/<batch-id>/` without any
  explicit `record-event` calls. `claim` emits `claim.acquired` (agent, target,
  branch, and generation/instance metadata), non-terminal `release` emits
  `claim.released` (final claim status plus `release_mode`/handoff fields when
  present), and `heartbeat` emits `phase.changed` (`previous_phase` -> `phase`)
  only on an actual phase transition. Each emit is append-only, best-effort (a
  failed event write warns on stderr and never fails the claim/heartbeat/release
  operation), and gated on a known `batch_id`. Terminal releases keep emitting
  the richer `lane_closed` event and do not double-emit `claim.released`; the
  prior release-only `handoff` event type is now the generalized `claim.released`
  event. No gem has been published, so no migration is required.
- A schema-first v1 batch blocker contract keyed by `(workspace, batch_id)` that
  persists a structured blocker (`message`, a non-empty `decisions` list, and an
  optional `recommendedReply`) when a supervisor blocks on operator authority, so
  the dashboard renders the Blocker panel instead of reconstructing decisions from
  lane `blockedOn` dependencies. `recommendedReply` is signaled absent by omission
  only (never `null`); conformance and panel-render fixtures ship beside the schema
  while capture stays deferred, and a batch with no structured blocker keeps the
  dashboard's `blockedOn`-derived fallback.
- A schema-first v1 batch completion-report contract keyed by `(workspace, batch_id)` that
  persists a completed batch's audit (`verdict` + free-form `author` that folds
  version and timestamp), completion report (`state`, `receipts`, `baseline`,
  per-lane `outcomes`, and optional `usage`/`tokensTotal`/`cost`/`duration`
  metrics), and canonical `finalReport`, so the dashboard drawer renders them
  instead of a degrade note. The dashboard-rendered payload follows dashboard #82
  verbatim (camelCase), while the envelope keeps snake_case; optional metrics send
  `null`/`"—"` and are never omitted or fabricated, archive-ready requires
  `state.live`/`audit`/`receipts`, and conformance plus a drawer-render replay
  ship beside the schema while capture stays deferred.
- A schema-first v1 batch merge-authority contract that persists the declared
  authority additively on the batch manifest as the canonical short enum
  `none | ask | auto` (the pr-batch launch `auto_merge_when_gates_pass` maps to
  `auto`), so the dashboard renders the Merge auth field. It is optional and
  signaled absent by omission only (never `null`), so a legacy batch degrades to
  an em dash distinct from an explicit `none`; conformance and drawer fixtures
  live beside the schema while launch capture stays deferred.
- A schema-first v1 lane route contract for the bound model + reasoning effort,
  emitted additively on a claim/heartbeat/lane-manifest record as either the
  compact `model/effort` string or the equivalent `{ model, effort }` object
  (both canonicalize to the same chip). Route is optional and signaled absent by
  omission only (never `null`), so the dashboard degrades a missing route to a
  hidden/em-dash chip; conformance, both-form, and chip-rendering fixtures live
  beside the schema while emit paths remain deferred.
- A schema-first v1 usage record keyed by
  `(workspace, repo, batch_id, lane_name, agent_id, target, model)` for
  per-model token and estimated-cost telemetry, with an additive optional
  `usage` status projection the dashboard aggregates into tokens-by-model and
  per-batch token/cost tiles. Token counts and cost are optional metrics that
  send `null` or the em dash `"—"` when unknown and are never omitted or
  fabricated as zero; conformance, discipline, aggregation replay, and
  duplicate-key procedural fixtures live beside the schema, while runtime
  reporting and pricing remain deferred.
- An idempotent local `agent-coord-harvest` pipeline that projects allowlisted
  coordination, GitHub, Codex, and Claude aggregate metadata into a versioned
  SQLite ledger with normalized joins, conservative target outcomes, integer
  micro-USD pricing, exact-lane cost allocation, review-economics scorecards,
  transcript-safe error handling, and an opt-in simulation verifier rollup.
- A canonical heartbeat/event status vocabulary enforced at the CLI write
  path: snake_case working and terminal sets with a known-alias map (terminal
  synonyms such as `completed`, hyphen/case twins such as
  `waiting-on-checks-or-review`, and spelling twins such as `in_process`) are
  coerced on `heartbeat` and ordinary `record-event` writes, keeping the
  caller's original spelling in `status_raw` when it differs; unknown values
  warn on stderr and are preserved verbatim with a `status_raw` copy without
  changing exit codes. `status --json` projects `status_raw`,
  `config show --json` publishes the vocabulary and alias map under
  `heartbeat_status_vocabulary`, dependency gating accepts the canonical
  dependency-satisfying statuses plus legacy `complete`/`completed` rows,
  `released` deliberately stays un-aliased and non-dependency-satisfying
  because it can mean a claim handoff rather than completion, and
  `gc` classifies all canonical terminal statuses as `terminal_heartbeat`
  while legacy non-canonical rows keep dead-heartbeat reclamation.
- Non-secret machine/session attribution from `AGENT_COORD_MACHINE_ID` plus
  `AGENT_COORD_SESSION_ID` falling back to `CODEX_THREAD_ID`: coordination
  writes stamp `machine_id`, `session_id`, and `session_source` into claims,
  heartbeats, and events; the tuple is atomic per write in both directions, so
  a machine change without a resolved session clears stale session fields and a
  session change without a declared machine clears the stale machine id instead
  of pairing halves resolved on different writes; `status --json` projects the
  fields; terminal
  closeouts resolve `closed_by.machine` from the environment before the `--host`
  fallback, and machine attribution never fences an identical terminal replay
  (the authoritative first closeout keeps its recorded machine while the
  variable or `--host` may appear, change, or disappear before a retry); `doctor --deep` reports an `environment_identity` block that
  fails with exit `2` when the environment machine contradicts the
  authenticated `/v1/whoami` token machine; and `doctor --stack-json` carries
  the same comparison as an `identity.machine` component check that fails on a
  mismatch and is skipped when unverifiable.
- `agent-coord doctor --stack-json`, a read-only schema v1 component report with
  exits `0` healthy, `1` degraded, `2` failed, and `64` invalid usage; it
  strictly requires exactly one direct `--state-root`, `--api-url`, or
  `--backend` selector. The contract lives in the README's
  [doctor setup section](README.md#setup).
- A schema-first v1 capacity-reservation contract for authoritative capacity
  profiles, enabled inboxes, persisted blocked-lane occupancy, and owner-fenced
  per-lane holds, with fail-closed contention, TTL, idempotency, and partial
  consume/release replay fixtures; runtime CLI/Worker operations remain deferred.
- A schema-first v1 host-limit record keyed by explicit `quota_host` and an
  additive optional status projection contract, with conformance, composite-key,
  and two-lane replay fixtures; runtime reporting and UI remain explicitly
  deferred while provider facts are unknown.
- Archive-first state retention with `agent-coord gc`, explicit dry-run/execute
  modes, 7-day hot and 30-day archive defaults, synthetic-state markers,
  terminal event compaction, local/HTTP parity, and a graveyard replay harness.
- Terminal lane closeout semantics where ordinary records remain v1 and
  `lane_closed` events use v2, with atomic `release --terminal` claim
  reconciliation and automatic batch completion.
- `register-batch --launch-prompt PATH|-` support for exact launch prompt
  capture from files or stdin, with controlled invalid input failures that
  perform no state writes.
- A clearly labeled zero-config local-store default for single-machine
  coordination; shared or multi-machine coordination still requires explicit
  HTTP configuration.
- A deterministic `agent-coord demo` walkthrough that uses isolated temporary
  state and does not write remote state.
- Reviewable RubyGem packaging for the `agent-coord` CLI.
- An explicit Ruby support floor and CI coverage for it.
- A placeholder-only `curl` walkthrough for the Worker state protocol.
- Deep HTTP doctor checks for every state resource, authenticated machine scope
  reporting, and actionable stale-token recovery guidance.
- A backend rotation runbook and token provisioning support for named D1
  databases and safe machine-token rotation.

### Changed

- Split-brain configuration is now enforced instead of merely advised. When a
  consumer env file configures `AGENT_COORD_API_URL` but was never sourced, and
  the CLI therefore fell back to the *implicit* local state root, the write
  commands `claim`, `release`, `heartbeat`, `record-event`, and `register-batch`
  hard stop with the existing operational exit code `2` and an error naming the
  offending env file and the three escape hatches (source the env file, pass
  `--state-root`/`AGENT_COORD_STATE_ROOT`, or set `AGENT_COORD_LOCAL=1`).
  `doctor` reports the same condition as `status: split_brain` with a new
  `split_brain_env_file` field, emitting its full report before exiting `2`.
  Read commands keep the advisory warning and exit `0`, `gc` is unaffected, the
  `doctor --stack-json` component contract is unchanged, and local-only users
  without a consumer env file see no behavior change (issue #97). No gem has
  been published, so no migration is required.
- Token provisioning now requires explicit read/write scopes, with `--all-state`
  available only as an explicit opt-out for trusted single-operator deployments.
- Documented the `LocalStore` symlink trust boundary: explicitly selected
  top-level roots remain trusted, while deep reads fail closed on top-level
  state-prefix and deeper descendant links using check-then-use guards rather
  than atomic filesystem traversal.

### Fixed

- `agent-coord log` now matches a target on the work item it names rather than on
  its literal spelling, so one item's custody trail stops splitting into partial
  answers. Issues and pull requests share one number sequence per repository, and
  the store holds the same item as `319`, `issue:319`, and `pr:319`; every
  spelling now returns the whole trail. Against the live fleet backend,
  `--target 319` returned 7 events and `--target issue:319` returned 28 for the
  same issue, with neither reporting that it was showing a share of the history;
  all spellings now return the union of 35. A trailing segment stays a lane within
  the item (`issue:319:qa`): asking for the item covers its lanes, asking for a
  lane stays narrow. Claim keys are unchanged — this is a read-path identity only,
  because a lane holds its own lease and merging keys would break exclusion. The
  reported claim follows that same rule: it folds casing and kind prefixes, which
  name one lease, but matches the lane exactly, so a parent and a lane that are
  live at the same time are each reported under their own query instead of the
  newer one hiding the other (issue #141).
- `agent-coord log --json` now reports `work_item.matched_targets` and a `trail`
  of `complete` or `incomplete`. The degraded-listing warning went only to stderr,
  so a trail cut short by a scoped token was byte-identical to a complete empty
  one for any JSON consumer, and "searched everything, found nothing" could not be
  told apart from "could not search" (issue #141).
- `agent-coord status --repo R --target N` now reports the `batches` and `events`
  sections it does not read as `null` rather than as empty arrays, and its section
  note names `agent-coord log` as the command that can answer for that target.
  Claims and heartbeats are cleared on release and expiry, so target scope alone
  cannot tell "never worked" from "worked and finished" — and two empty arrays
  read like an answer to exactly that question (issue #141).
- The consumer env-file probe no longer reads a commented-out assignment such as
  `AGENT_COORD_API_URL= # remote disabled` as a configured fleet URL. Sourcing
  that file leaves the variable empty, so it selects no fleet backend; the value
  is now parsed the way a shell would, with quoted values taken verbatim and an
  unquoted trailing comment excluded, while a `#` inside an unquoted URL stays
  part of the value. This also corrects the pre-existing split-brain advisory,
  which had the same false positive (issue #97). No gem has been published, so
  no migration is required.
- Lightweight and stack doctor checks now reject an archived legacy GitHub
  backend instead of reporting its readable but permanently read-only state as
  healthy, with guidance to configure the HTTP backend or another writable
  repository. Unreadable or malformed backend metadata is treated as a doctor
  failure rather than assumed writable.
- Batch status JSON now includes persisted launch prompts.
- Local doctor/status now warn when a configured consumer API environment would
  otherwise leave the CLI and dashboard on different backends.

No gem has been published and no release has been tagged.
