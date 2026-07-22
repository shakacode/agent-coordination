# 0010. Lane route state contract foundation

Date: 2026-07-22
Status: accepted

## Context

The Coordination Dashboard shows each lane/work item's model + effort route (for
example `gpt-5.6-sol/xhigh` or `claude-opus-4-8/high`) as a chip on the lane row
and in the job drawer, but the coordination protocol emits no route, so the
dashboard degrades the Route field to an em dash (dashboard consumer
shakacode/agent-coordination-dashboard#80). The route is a natural attribute of a
lane wherever it is claimed or heartbeated; it is not a separate keyed record.

ADR [0003](0003-decouple-dashboard-via-state-contract.md) makes this repository
the producer of versioned state contracts while the dashboard remains a separate
consumer.

## Decision

Publish the versioned JSON Schema at
[`schema/state/v1/route/route.schema.json`](../../schema/state/v1/route/route.schema.json).
A route is the bound model and reasoning effort, expressed in either of two
interchangeable forms:

- the compact `"model/effort"` string with exactly one slash and no whitespace
  (for example `gpt-5.6-sol/xhigh`), or
- the structured object `{ "model": ..., "effort": ... }`.

Both canonicalize to the same model and effort; the compact string is
`model + "/" + effort`. The compact form assumes a slashless model identifier;
the structured form is unambiguous when a model identifier itself contains a
slash. `effort` is a provider-neutral label (for example `xhigh`, `high`,
`medium`, `low`, `none`) and the vocabulary is intentionally open.

Route is emitted additively via the `lane_route_projection` fragment: a claim,
heartbeat, or lane-manifest record may carry an optional `route` property beside
its existing properties. Route is optional and there is exactly one way to signal
"no route" — omit the property — so `route` is never `null`. This single-absent
representation deliberately avoids a second sentinel; the dashboard degrades an
absent route to a hidden/em-dash chip.

Route is an attribute of the record it rides on rather than a standalone entity,
so it declares no `x-logical-key` or `x-storage-key`; it inherits the identity
(and workspace) of its host claim/heartbeat/lane record.

## Consequences

- Positive and negative fixtures live beside the schema, covering both route
  forms, malformed compact strings (missing or empty parts, extra slash),
  malformed objects (missing fields, empty model, unexpected fields), a `null`
  route, and a wrong-typed route. A chip-rendering replay proves both forms
  canonicalize to the same chip and an absent route renders hidden.
- Breaking changes to the route shape require `schema/state/v2`; additive
  optional fields may extend v1.
- This foundation does not add emit paths, model/effort detection, persistence,
  or dashboard behavior. Absent route keeps the dashboard's em-dash degrade; the
  contract never invents a route.
