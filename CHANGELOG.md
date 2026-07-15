# Changelog

All notable changes to Agent Coordination will be documented in this file.
The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
when releases begin.

## [Unreleased]

### Added

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
