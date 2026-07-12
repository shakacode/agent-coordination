# 0006. Archive-first state retention and garbage collection

Date: 2026-07-12
Status: accepted

## Context

Terminal closeout makes completion authoritative, but coordination stores still
accumulate released claims, dead heartbeats, completed batches, terminal event
history, and synthetic smoke records. Leaving that data in the hot prefixes
makes current-state reads noisy and causes unbounded list growth.

## Decision

`agent-coord gc` is the protocol-plane retention operation for every store. Its
default policy keeps terminal state hot for 7 days, moves it to an archive tier
for 30 more days, and then deletes the archive envelope. Synthetic state marked
with `synthetic: true` uses a 1-day hot window. The policy is inspectable through
`config --json` and overrideable per invocation.

Archiving is copy-before-delete. The destination is created under `archive/`
with the original compare-and-swap version captured by the source read; only a
successful archive create (or an identical retry) permits source deletion. A
concurrent source change stops GC. Archive deletion is also version guarded.
This makes retries safe: a crash can leave both copies temporarily, but it
cannot silently discard the only copy.

Claims are eligible only when released or explicitly terminal. Heartbeats are
eligible when terminal or after their protocol liveness reaches `dead`.
Batches are eligible only when `status` is `completed`. Events are compacted per
repository target only after a schema-v2 `lane_closed` event declares `done`,
`abandoned`, or `superseded`, and every current event for that target has passed
its own hot window. The compacted envelope lists all consumed paths while its
records retain first, last, and phase transitions and omit repeated renewals.
Its path includes a deterministic digest of the complete source-path set:
identical retries remain idempotent, while later valid terminal replays produce
a separate immutable generation rather than conflicting with or mutating the
first archive. GC recognizes a terminal marker only when all required
`lane_closed` v2 fields and their destructive-eligibility shapes conform,
including `workspace`, `closed_by`, and `at`. Protocol-declared terminal state
therefore remains the eligibility source; GC does not infer completion from
GitHub.

Normal status reads never scan `archive/`. Operators opt in with unscoped
`status --include-archived`. The HTTP API accepts the mirrored archive path
grammar and exposes compare-and-swap DELETE so local and HTTP execution share
the same semantics. Both the CLI preflight and HTTP Worker cap serialized
archive envelopes at 1 MiB; an oversized plan fails before GC writes anything,
while active HTTP records keep their existing 256 KiB limit.

## Consequences

- Current-state consumers stay clean without presentation-layer age filtering.
- Dry-run and execute share one deterministic action plan.
- Event history remains replayable as a compacted archive envelope.
- Synthetic simulation records are identifiable without name heuristics.
- Archive readers must consume the published archive envelope v1 contract.
- Scheduled Worker triggers remain a separate operational follow-up; this ADR
  defines the bounded command and backend contract they can invoke.
