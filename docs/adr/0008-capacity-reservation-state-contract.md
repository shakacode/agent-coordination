# 0008. Capacity reservation state contract foundation

Date: 2026-07-14
Status: accepted

## Context

Planning currently reads capacity and launches later. Two planners can therefore
observe the same final slot and both proceed. A local-only hold cannot close that
race because the authoritative coordination state is shared through the protocol
plane.

ADR [0004](0004-tenancy-ready-state-contract.md) requires workspace-aware state,
and ADR [0007](0007-host-limit-state-contract.md) publishes the reversible
workspace segment encoding used here. Host limits are eligibility state, not
numeric capacity. Issue #6 additionally requires authoritative capacity,
enabled-inbox, and blocked-lane inputs before an atomic reservation can be
implemented safely.

## Decision

The MIT protocol plane owns four schema-first record families under
[`schema/state/v1/capacity-reservation/`](../../schema/state/v1/capacity-reservation/):

- `capacity_profile` is keyed by `(workspace, capacity_profile_id)` and publishes
  enabled/disabled state plus `max_concurrency`.
- `inbox` is keyed by `(workspace, inbox_id)`, is enabled or disabled, and binds
  admission from that inbox to one capacity profile. Multiple inboxes may share
  one profile; they do not partition its capacity.
- `lane_occupancy` is keyed by `(workspace, lane_ref)` for stable
  `<batch-id>:<lane-name>` references. `occupied` and `blocked` consume capacity;
  `terminal` and `cancelled` do not. A blocked record persists independently of
  heartbeat liveness, so a blocked lane cannot disappear from arithmetic merely
  because its worker is offline.
- `capacity_reservation` is keyed by `(workspace, reservation_id)` and owns one
  or more unique lane holds. Each hold moves monotonically from `active` to
  `consumed`, `released`, or `expired`; terminal holds never revive. Aggregate
  state is derived from the holds rather than stored separately.

These are protocol primitives. Product-plane planning, ranking, scheduling,
approval UI, and policy remain outside this repository. Runtime persistence,
Worker routes, and CLI verbs are separately sequenced implementation work; this
decision publishes no daemon or scheduler.

Every path segment uses the ADR 0007 rule: encode UTF-8 bytes, leave only ASCII
letters, digits, `_`, and `-` literal, and percent-encode every other byte with
uppercase hexadecimal. Self-hosted records use workspace `default`.

### Capacity predicate

Reservation creation is all-or-nothing and must evaluate one authoritative
snapshot in the same atomic backend operation:

```text
available = enabled capacity_profile.max_concurrency
          - count(unique occupied lane refs union active reserved lane refs)

accept only when the enabled inbox targets that profile
and available >= count(requested new unique lane refs)
```

`occupied` and `blocked` lane-occupancy records count. `terminal` and
`cancelled` records do not. A lane appearing both as occupied and actively
reserved counts once during reservation-to-launch conversion. An active hold
counts only while server time is strictly before `expires_at`; at or after the
boundary it is expired for arithmetic even if cleanup has not materialized the
terminal state.

Missing, malformed, disabled, cross-workspace, or mismatched capacity profile,
inbox, occupancy, or reservation inputs refuse the request. The protocol never
infers availability from absence.

### Identity, TTL, and lifecycle

The authenticated workspace/machine plus planner `owner_id` and per-attempt
`instance_id` form the owner tuple. Only that tuple may consume or release.
Cross-machine takeover and renewal are out of scope for v1.

TTL defaults to 900 seconds and accepts 60 through 3600 seconds. The producer
uses server time for `created_at` and must derive `expires_at` exactly as
`created_at + ttl_seconds`; readers fail closed when that invariant does not
hold. `consume` is idempotent, requires an active matching hold before expiry,
and requires the same lane to be observably occupied. `release` idempotently
changes only the remaining active holds; already consumed or terminal holds
remain unchanged. Expiry frees active capacity without requiring cleanup.

The same reservation ID with the same canonical payload is idempotent. Reusing
the ID with a changed payload is a conflict. The same active lane ref cannot be
held by two reservations. For batch-scoped reservations, producers must verify
that every lane ref belongs to `batch_id`; JSON Schema validates the shapes but
cannot compare those values. `batch_id` uses the same representable prefix
character set as lane refs: ASCII letters, digits, `_`, `.`, `:`, and `-`.
It is capped at 254 characters so the 256-character lane ref still has room for
the required delimiter and a non-empty lane name.

Release and new-reservation writes serialize through the same atomic backend
boundary. A new request ordered before release is refused while the old hold is
active; one ordered after release may succeed. The released hold remains
terminal in either ordering and is never revived.

Host-limit state from ADR 0007 remains a separate eligibility check and is never
folded into numeric reservation arithmetic.

### Future CLI and API contract

The later runtime boundary may add `reserve`, `consume-reservation`, and
`release-reservation` CLI commands and atomic Worker operations. Capacity
refusal is additive `RESERVATION_REFUSED` exit code 4; it does not overload
`CLAIM_REFUSED` exit code 3. Existing usage and operational exit codes remain
unchanged.

Runtime authorization must derive workspace and owner machine from the bearer
credential, use the narrow record prefixes required by each caller, and compare
the full owner tuple on consume/release. A launcher must consume a hold in the
same atomic acquisition that establishes observable lane occupancy; a
local-file-only pseudo-reservation is non-conforming.

## Replay contract

Checked-in positive, negative, and replay fixtures prove:

- two planners racing for the final slot produce one acceptance and one refusal;
- multi-source occupied/reserved overlap counts once;
- identical retry is idempotent and changed payload conflicts;
- disabled, missing, or mismatched authoritative inputs fail closed;
- blocked-without-heartbeat occupancy remains explicit;
- TTL is active before expiry and inactive at the boundary;
- mismatched `created_at`, `ttl_seconds`, and `expires_at` fail closed;
- owner mismatch refuses consume/release;
- partial consume followed by release preserves consumed holds and frees only
  the active remainder;
- batch-scoped lane refs match their batch producer identity;
- active lane refs are unique across existing reservations;
- unchanged active records stop consuming capacity at the TTL boundary without
  cleanup;
- release-versus-new-reservation ordering never revives the released hold.

Runtime work must extend these fixtures with local and HTTP contention evidence
before adding subprocess launch behavior.

## Consequences

- Issue #6 now has an implementation-ready producer/consumer contract without
  guessing scheduling policy.
- External dashboards and product-plane planners can consume the same versioned
  record shapes without becoming protocol writers by implication.
- The first runtime PR stays bounded to atomic persistence, status projection,
  CLI/API parity, authorization, and deterministic contention tests.
- Schedulers, launchers, target-claim changes, provider quota detection,
  dashboard UI, account rotation/pooling, and cross-machine takeover remain
  explicit non-goals.
