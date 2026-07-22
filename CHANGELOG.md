# Changelog

All notable changes to Agent Coordination will be documented in this file.
The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
when releases begin.

## [Unreleased]

### Added

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

- Batch status JSON now includes persisted launch prompts.
- Local doctor/status now warn when a configured consumer API environment would
  otherwise leave the CLI and dashboard on different backends.

No gem has been published and no release has been tagged.
