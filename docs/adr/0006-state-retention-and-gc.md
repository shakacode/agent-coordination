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
Batches are eligible only when `status` is `completed`. The synthetic marker
selects the shorter window only after those family-specific conditions hold;
it never makes active claims, live heartbeats, or incomplete batches eligible.
Events are compacted per batch, lane, repository, and target after a schema-v2
`lane_closed` event declares `done`, `abandoned`, or `superseded` and every
current event in that lane group has passed its own hot window. A lane-less
event is normalized to the sole valid terminal lane for identical
batch/repository/target provenance; if that choice is ambiguous or absent it
stays in the explicit legacy group, preventing sibling-lane sweeps. A fully synthetic group without a valid
terminal marker is also compacted once each event passes the synthetic window.
Such orphan groups may lack repository and/or target metadata: batch, lane, and
available provenance form a deterministic safe identity, preventing simulation
orphans from leaking while leaving non-synthetic or unaged orphans untouched.
The compacted envelope lists all consumed paths while its records retain first,
last, every valid terminal event, and phase transitions and omit repeated
renewals.
Its path includes deterministic digests of lane/provenance identity plus the
complete source paths and recursively key-sorted JSON content: identical retries
remain idempotent, while changed content at a stable source path or later valid
terminal replays produce a separate immutable generation rather than conflicting
with or mutating the first archive. GC recognizes a terminal marker only when
all required
`lane_closed` v2 fields and their destructive-eligibility shapes conform,
including `workspace`, `closed_by`, and `at`. Protocol-declared terminal state
therefore remains the eligibility source; GC does not infer completion from
GitHub.

Normal status reads never scan `archive/`. Operators opt in with unscoped
`status --include-archived`. The HTTP API accepts the mirrored archive path
grammar and exposes compare-and-swap DELETE so local and HTTP execution share
the same semantics. Active deletion requires write coverage for both the active
path and its archive mirror, while archive deletion requires archive write
coverage. This derives GC authority from existing prefix lists without a token
schema migration. Dry-run and execute run the same CLI size preflight, and the
HTTP Worker enforces the same 1 MiB archive-envelope cap; an oversized plan
fails before GC writes anything, while active HTTP records keep their existing
256 KiB limit. Malformed or forward-incompatible records deliberately fail the
whole plan with their source path; operators repair the record or upgrade the
consumer before retrying.
Active state paths remain capped at 512 UTF-8 bytes. Archive paths permit 520
bytes only for the `archive/` prefix over a suffix that independently passes the
512-byte active-path bound.

## Consequences

- Current-state consumers stay clean without presentation-layer age filtering.
- Dry-run and execute share one deterministic action plan.
- Event history remains replayable as a compacted archive envelope.
- Interrupted multi-source deletion can leave a safe expiring duplicate
  envelope; retry remains copy-before-delete and fail-fast.
- Source mutation after archive creation can similarly leave a stale expiring
  envelope, while source CAS prevents deletion of the changed live record.
- Synthetic simulation records are identifiable without name heuristics.
- Archive readers must consume the published archive envelope v1 contract.
- Scheduled Worker triggers remain a separate operational follow-up; this ADR
  defines the bounded command and backend contract they can invoke.
