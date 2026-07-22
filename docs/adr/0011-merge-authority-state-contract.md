# 0011. Batch merge-authority state contract foundation

Date: 2026-07-22
Status: accepted

## Context

The Coordination Dashboard shows each batch's merge authority (`ask` / `auto`) in
the batch detail drawer and job provenance, but the coordination protocol does
not persist merge authority, so the dashboard degrades the Merge auth field to an
em dash (dashboard consumer shakacode/agent-coordination-dashboard#81). The
pr-batch launch prompt already declares `merge_authority`, but that declaration
is not captured into batch state.

ADR [0003](0003-decouple-dashboard-via-state-contract.md) makes this repository
the producer of versioned state contracts while the dashboard remains a separate
consumer.

## Decision

Publish the versioned JSON Schema at
[`schema/state/v1/merge-authority/merge-authority.schema.json`](../../schema/state/v1/merge-authority/merge-authority.schema.json).
`merge_authority` is persisted additively on the batch manifest / launch-metadata
record via the `batch_manifest_projection` fragment: a batch manifest may carry
an optional `merge_authority` beside its existing properties.

The canonical persisted vocabulary is the short enum `none | ask | auto`:

- `auto` — the supervisor may merge when gates pass.
- `ask` — the supervisor surfaces one merge decision for the operator.
- `none` — the supervisor never merges.

The pr-batch launch vocabulary maps to these canonical values before
persistence: `auto_merge_when_gates_pass` → `auto`, `ask` → `ask`, `none` →
`none`. The verbose launch string `auto_merge_when_gates_pass` is not a persisted
value, so there is a single canonical form per authority and the dashboard reads
one short value.

`merge_authority` is optional, and the only way to signal an undeclared authority
is to omit the property — it is never `null`. This single-absent representation
avoids a second sentinel; the dashboard degrades an absent authority to an
em-dash Merge auth field, distinct from an explicit `none`.

merge_authority is a batch attribute rather than a standalone entity, so it
declares no `x-logical-key` or `x-storage-key`; it inherits the identity of the
batch manifest it rides on.

## Consequences

- Positive fixtures cover all three authorities and an absent authority; negative
  fixtures cover the verbose launch string, an unknown value, a wrong case, a
  `null`, and a wrong type. A drawer replay proves each authority renders and an
  absent authority renders an em dash.
- Breaking changes to the vocabulary require `schema/state/v2`; additive optional
  fields may extend v1.
- This foundation does not add launch capture, persistence routes, or dashboard
  behavior. An in-progress or legacy batch with no persisted authority keeps the
  dashboard's em-dash degrade; the contract never invents an authority.
