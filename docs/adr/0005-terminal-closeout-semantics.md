# 0005. Terminal closeout semantics and truth precedence

Date: 2026-07-12
Status: accepted

## Context

Claims and heartbeats describe active work, but the original state contract had
no durable way to say that a lane was finished. A released or expired claim
could mean successful completion, abandonment, handoff, or lost liveness. That
forced every consumer to infer outcomes from GitHub and made stale records look
current indefinitely.

ADR [0003](0003-decouple-dashboard-via-state-contract.md) requires a published,
versioned producer/consumer contract. ADR
[0004](0004-tenancy-ready-state-contract.md) requires its records to name a
`workspace`, defaulted to `default` for self-hosted use.

## Decision

The published `lane_closed` event contract is version 2 and carries a terminal
value of `done`, `abandoned`, or `superseded`. It identifies the repository and
target, closing agent and machine, workspace, and optional batch, lane,
pull-request state, and replayable evidence URL. Baseline claims, heartbeats,
batches, and ordinary events remain schema version 1; the CLI advertises the
specialized `lane_closed_schema_version` separately so it never labels those
ordinary records as conforming to a contract that only describes closeout.

`agent-coord release --terminal STATE` is the closeout command. It records the
event, releases the held claim, stamps the matching registered lane, and marks
the batch `completed` when every lane is terminal. The explicit two-step
`record-event --type lane_closed` form updates the same lane and batch state for
hosts that manage release separately. Terminal closeout and handoff are distinct
and cannot be combined.

Consumers use this precedence rule:

1. Protocol-declared lane terminal state.
2. Live coordination state such as a non-terminal heartbeat.
3. GitHub-derived state only when the protocol has no terminal declaration.

The coordination dashboard remains a read-only consumer. This decision changes
the protocol it reads; it does not move reconciliation or write behavior into
the dashboard and does not create a release process.

## Consequences

- Closeout leaves no live-looking claim or lane while retaining an auditable
  event and released claim record.
- Batch completion is a write-time protocol fact, so consumers do not need to
  derive it independently.
- The lane-close contract v2 is intentionally incompatible with producers that
  claim v2 while omitting terminal closeout fields. The checked-in conformance
  fixture gives Ruby and external TypeScript consumers the same example without
  changing the baseline v1 record family.
- GitHub remains a useful fallback for legacy or interrupted runs, but it cannot
  override an explicit protocol terminal result.
- The `workspace` field is present now with the self-hosted `default`; broader
  tenancy and product-plane behavior remain outside this change.
