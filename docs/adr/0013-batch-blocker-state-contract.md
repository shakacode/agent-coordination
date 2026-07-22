# 0013. Batch blocker state contract foundation

Date: 2026-07-22
Status: accepted

## Context

For a blocked batch, the Coordination Dashboard renders a structured Blocker
panel: a message, a list of required decisions, and a recommended reply. The
coordination protocol emits no structured blocker, so the dashboard reconstructs
decisions from lane `blockedOn` dependencies and shows a degrade note (dashboard
consumer shakacode/agent-coordination-dashboard#83).

ADR [0003](0003-decouple-dashboard-via-state-contract.md) makes this repository
the producer of versioned state contracts while the dashboard remains a separate
consumer. ADR [0004](0004-tenancy-ready-state-contract.md) requires `workspace`
as a first-class key dimension.

## Decision

Publish the versioned JSON Schema at
[`schema/state/v1/batch-blocker/batch-blocker.schema.json`](../../schema/state/v1/batch-blocker/batch-blocker.schema.json),
keyed by `(workspace, batch_id)`. When a supervisor blocks on operator authority
it persists a `blocker` payload on the batch:

- `message` (required): why the batch is blocked on operator authority.
- `decisions` (required): a non-empty list of non-empty strings — the required
  operator decisions. A structured blocker asserts at least one decision; an
  empty list is not meaningful and should degrade to the dashboard's
  `blockedOn`-derived fallback instead.
- `recommendedReply` (optional): a suggested operator reply. There is exactly one
  way to signal no recommendation — omit the property — so it is never `null` or
  empty. This single-absent representation avoids a second sentinel.

The dashboard-rendered payload uses the dashboard's field names (including
camelCase `recommendedReply`); the record envelope (`schema_version`,
`batch_id`), the `workspace` dimension, and the contract metadata keep this
repository's snake_case convention, consistent with the batch-completion contract
(ADR 0012).

## Consequences

- Positive fixtures cover a full blocker and a blocker with no recommended reply.
  Negative fixtures cover a missing message, an empty message, missing/empty
  decisions, a non-string decision, an empty decision string, a `null`
  recommended reply, a missing `workspace`, a missing `blocker`, and an unknown
  field. A panel replay proves the message, decisions, and an omitted recommended
  reply render as expected.
- Breaking changes to the blocker shape require `schema/state/v2`; additive
  optional fields may extend v1.
- This foundation does not add capture, persistence routes, or dashboard
  behavior. A batch with no structured blocker keeps the dashboard's
  `blockedOn`-derived fallback and degrade note; the contract never invents a
  blocker.
