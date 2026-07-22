# 0012. Batch completion-report state contract foundation

Date: 2026-07-22
Status: accepted

## Context

The Coordination Dashboard's batch detail drawer renders a completed-batch audit
(verdict + author), a completion report (per-lane outcome table), and a final
report (free-text handoff), but the coordination protocol emits none of these, so
the dashboard degrades that whole region to a note (dashboard consumer
shakacode/agent-coordination-dashboard#82). These already exist as human
artifacts in pr-batch handoffs; this contract captures them into batch state.

Dashboard #82 publishes the report contract the drawer renders and states that
producers must follow it exactly. That contract uses camelCase field names such
as `finalReport`, `tokensTotal`, and `state.replay`.

ADR [0003](0003-decouple-dashboard-via-state-contract.md) makes this repository
the producer of versioned state contracts while the dashboard remains a separate
consumer.

## Decision

Publish the versioned JSON Schema at
[`schema/state/v1/batch-completion/batch-completion.schema.json`](../../schema/state/v1/batch-completion/batch-completion.schema.json),
keyed by `(workspace, batch_id)`. Per ADR [0004](0004-tenancy-ready-state-contract.md),
`workspace` is a first-class key dimension (default `default`), so two tenants
sharing a `batch_id` do not overwrite each other's report. The record carries
three dashboard-rendered payload members plus a protocol envelope:

- `audit: { verdict: "clean" | "findings" | "pending", author }`. `author` is
  free-form and folds the version and timestamp (for example
  `"justin808 · v1 durable · 2026-07-20T16:24:07Z"`); there is deliberately no
  separate `version` field, so `audit` rejects one.
- `completion: { state, receipts, baseline, outcomes, usage, tokensTotal, cost,
  duration }`. `state.live`, `receipts` (at least one durable v1 receipt),
  `baseline` (with a short display `path`), and `outcomes` are structural.
  `usage`, `tokensTotal`, `cost`, `duration`, and `state.replay` are optional
  metrics: they send `null` or the em dash `"—"` when unknown and are **never
  omitted or fabricated** (the schema rejects a dropped metric key and a
  fabricated string for the numeric metrics). A numeric `duration` is seconds and
  cannot be negative. Any `{ k, v }` metadata pair may carry an optional `href`;
  an outcome keeps plain-text refs unless it also sends a `links: [{ label, href }]`
  array. An outcome row stays strict (`additionalProperties: false`) with the
  documented `route`/`pr`/`sha`/`issue` producer fields, so a typo'd key is
  rejected rather than silently dropped.
- `finalReport`: the canonical handoff text, rendered verbatim.

**Archive-ready** requires `state.live`, `audit`, and `receipts`.

### Field-name convention

The dashboard-rendered payload (`audit`, `completion`, `finalReport`, and nested
members including `tokensTotal` and `state.replay`) follows dashboard #82's report
contract verbatim, including its camelCase names, because that contract must be
followed exactly for the dashboard to render it. The record envelope
(`schema_version`, `batch_id`), the contract metadata (`x-record-family`,
`x-logical-key`), and the `k`/`v`/`href`/`path` metadata-pair keys keep this
repository's snake_case/short convention. This is a deliberate, documented
asymmetry: the payload is a consumer-dictated contract, the envelope is
protocol-plane state.

## Consequences

- Positive fixtures cover a full report, an archive-ready minimal report,
  plain-text outcomes, and each verdict. Negative fixtures cover a missing audit,
  missing/`null` final report, a bad verdict, empty receipts, a missing
  `state.live`, a missing `workspace`, an omitted optional metric, a fabricated
  metric string, a negative numeric duration, a separate `version` field, a link
  missing its `href`, a baseline missing its `path`, and an outcome with an
  unknown key. A drawer replay proves the audit chip, outcome rows, and that a
  `null` or `"—"` metric renders an em dash rather than a fabricated value.
- Breaking changes to the payload require `schema/state/v2`; additive optional
  fields may extend v1.
- This foundation does not add capture, persistence routes, or dashboard
  behavior. An in-progress or legacy batch with no record keeps the dashboard's
  degrade note; the contract never invents an audit, completion, or report.
