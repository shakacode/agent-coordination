# 0009. Usage record state contract foundation

Date: 2026-07-22
Status: accepted

## Context

The Coordination Dashboard renders tokens-by-model and per-batch token/cost
tiles, but the coordination protocol emits no token or cost telemetry, so the
dashboard degrades those fields to `—` (dashboard consumer
shakacode/agent-coordination-dashboard#79). Token counts and estimated cost are
often unknown at report time: a wrapper may not surface per-model tokens, and
cost depends on provider pricing the protocol plane must not guess. Fabricating
a zero for an unknown metric would silently corrupt aggregation.

ADR [0003](0003-decouple-dashboard-via-state-contract.md) makes this repository
the producer of versioned state contracts while the dashboard remains a separate
consumer. ADR [0004](0004-tenancy-ready-state-contract.md) requires `workspace`
as a first-class key dimension, with `default` reserved for self-hosting.

## Decision

Publish the versioned JSON Schema at
[`schema/state/v1/usage/usage-record.schema.json`](../../schema/state/v1/usage/usage-record.schema.json).
A usage record attributes input/output tokens and estimated cost to exactly one
model. Its logical key is
`(workspace, repo, batch_id, lane_name, agent_id, target, model)`, so one record
exists per model per lane/agent/target and consumers aggregate tokens-by-model
by grouping on `model`.

- `repo` is `owner/name`; `target` is the issue/PR or lane target; `batch_id`,
  `lane_name`, and `agent_id` are the emitting lane's coordinates. These match
  the dashboard's `repo` / `target` / `batchId` / `laneName` / `agentId` keys.
- `model` is the provider-neutral model identifier the tokens and cost belong to.
- `input_tokens`, `output_tokens`, and `cost` are **optional metrics**. When a
  value is unknown at report time the producer sends `null` or the em dash
  string `"—"` and never omits the key or emits a fabricated zero. The schema
  encodes this as a non-negative number, `null`, or `"—"` and rejects any other
  string, so an omitted metric key (a required-field violation) and a fabricated
  arbitrary string are both rejected.
- `currency` is an optional ISO 4217 unit label (absent means USD). It is a unit
  label rather than a metric, so it may be omitted.
- `reported_at` is the report time; a later report for the same logical key
  supersedes an earlier one.

The workspace-aware storage key reserved for a later runtime is
`usage/<workspace>/<repo>/<batch_id>/<lane_name>/<agent_id>/<target>/<model>.json`.
Every logical-key segment percent-encodes its UTF-8 bytes, leaving only ASCII
letters, digits, `_`, and `-` literal, because `repo` and identifier strings may
contain slashes or other separators (for example `owner/name` encodes its slash
as `%2F`). This ADR does not add that path to the CLI or Worker.

Status producers may add a top-level `usage` array holding at most one record per
logical key. The additive `status_projection` fragment permits existing status
properties (`claims`, `heartbeats`, `batches`, `events`), so embedding the
section is optional and backward compatible. Consumers aggregate tokens-by-model
and per-batch token/cost tiles from these records and exclude unknown (`null` or
`"—"`) metrics from sums rather than counting them as zero. The array publishes
`x-unique-key` metadata for the composite key, an unenforced producer invariant
because JSON Schema cannot enforce uniqueness by a subset of object properties.

## Consequences

- Positive, negative, procedural, and aggregation replay fixtures live beside the
  schema. The replay proves tokens-by-model and batch totals ignore unknown
  metrics without fabricating zeros.
- Breaking changes to key or field semantics require `schema/state/v2`; additive
  optional fields may extend v1.
- This foundation does not add reporting commands, persistence routes, provider
  token accounting, pricing tables, or dashboard behavior. Estimated cost and
  provider pricing remain producer inputs and stay `UNKNOWN` to this contract.
- Absent usage keeps the dashboard's `—` degrade; the contract never invents
  token counts or cost.
