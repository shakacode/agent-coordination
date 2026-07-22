# Changelog

All notable changes to Agent Coordination will be documented in this file.
The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
when releases begin.

## [Unreleased]

### Added

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

- Token provisioning now requires explicit read/write scopes, with `--all-state`
  available only as an explicit opt-out for trusted single-operator deployments.
- Documented the `LocalStore` symlink trust boundary: explicitly selected
  top-level roots remain trusted, while deep reads fail closed on top-level
  state-prefix and deeper descendant links using check-then-use guards rather
  than atomic filesystem traversal.

### Fixed

- Lightweight and stack doctor checks now reject an archived legacy GitHub
  backend instead of reporting its readable but permanently read-only state as
  healthy, with guidance to configure the HTTP backend or another writable
  repository. Unreadable or malformed backend metadata is treated as a doctor
  failure rather than assumed writable.
- Batch status JSON now includes persisted launch prompts.
- Local doctor/status now warn when a configured consumer API environment would
  otherwise leave the CLI and dashboard on different backends.

No gem has been published and no release has been tagged.
