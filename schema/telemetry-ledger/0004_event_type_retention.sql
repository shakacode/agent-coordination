-- Issue #112: restore event retention in the telemetry ledger.
--
-- The harvester clamps `events.event_type` through a closed allowlist, and that
-- allowlist had been fitted to the archived 2026-07-18 baseline rather than to
-- current CLI output: it intersected what `bin/agent-coord` emits at exactly
-- `lane_closed`, so the three auto-emitted lifecycle types and the four typed
-- operational signals all landed as SQL NULL. The write-time-validated
-- attributes those signals carry (`severity`, `category`, `kind`, `reason`)
-- had no column at all and were discarded at ingest.
--
-- Additive only. 0001-0003 are already applied and hash-pinned by
-- `Ledger#migrate!`, so they must never be edited; this file follows the
-- `ALTER TABLE ... ADD COLUMN` pattern established in 0003.

-- The raw `--type` string, recorded for every event that carried one,
-- regardless of whether it survived the allowlist. `event_type` stays clamped
-- so grouping is over a closed vocabulary; `event_type_raw` makes a value the
-- allowlist rejected countable instead of an invisible NULL.
--
-- Invariant: `event_type_raw` IS NULL if and only if the source event carried
-- no usable type -- absent, or nothing but whitespace. A control character is
-- not whitespace: a control-bearing value is stripped and digest-marked, never
-- trimmed into a value identical to its clean twin.
-- The value is sanitized (control characters removed, length bounded) but never
-- rejected; rejecting it would put the row back in the both-columns-NULL state
-- this column exists to eliminate. A value that had to be truncated carries a
-- short digest of the original, so two distinct oversized types cannot collapse
-- into one another and skew the drift counts. The digest suffix shape is
-- reserved: a value that already ends in it is routed through the sanitizer
-- too, so a clean value can never be stored as some other value's sanitized
-- form and a stored value wearing that shape is always sanitizer-produced.
ALTER TABLE events ADD COLUMN event_type_raw TEXT;

-- Typed operational-signal attributes. `severity`, `kind`, and `reason` mirror
-- the CLI's own write-time enums (AgentCoord::ERROR_SEVERITIES,
-- HUMAN_INTERVENTION_KINDS, HELP_REQUESTED_REASONS) so the ledger rejects a
-- value the CLI would have rejected. `category` is free-form and unbounded at
-- write time, so it has no CHECK and is stored sanitized-but-never-rejected,
-- the same treatment as `event_type_raw`: an `error` event's category is
-- required, and dropping an oversized one would destroy the friction
-- classifier this column exists to carry. The one difference is the literal
-- UNKNOWN, which `category` stores as NULL (it is a semantic classifier, and
-- this repo reads UNKNOWN as "no value") while `event_type_raw` keeps it
-- verbatim (that column is explicitly the raw string).
--
-- Deliberately absent: `from_route`, `to_route`, and `evidence`. `evidence` is
-- free prose and does not belong in a ledger analysis column; the route strings
-- are unbounded free text that duplicate the route/model dimension already
-- carried by `host_sessions`. Issue #143 needs only `escalation_requested`
-- counts, which `event_type` alone provides.
ALTER TABLE events ADD COLUMN severity TEXT
  CHECK (severity IN ('P0', 'P1', 'P2', 'P3') OR severity IS NULL);
ALTER TABLE events ADD COLUMN category TEXT;
ALTER TABLE events ADD COLUMN kind TEXT
  CHECK (kind IN ('takeover', 'supersede', 'manual-fix', 'drain') OR kind IS NULL);
ALTER TABLE events ADD COLUMN reason TEXT
  CHECK (reason IN ('blocked-user-input', 'question', 'permission') OR reason IS NULL);

-- The drift signal made queryable: an event whose raw type the ingest allowlist
-- did not recognize. A non-empty result means either an operator used an
-- ad-hoc `--type`, or the CLI gained an emitted type the harvester does not
-- classify yet -- the exact regression #112 records. Because a stored raw type
-- is never NULL when the source had one, no unrecognized type can escape this
-- view; `event_type_raw IS NULL` is the separate, and different, question of an
-- event that carried no type at all.
--
-- One known gap: the view keys on `event_type IS NULL`, so it does not surface
-- a control-bearing type whose trimmed form is allowlisted. Such a row is still
-- self-evidently inconsistent -- a clean `event_type` beside a digest-marked
-- `event_type_raw` -- but it is not counted here. The cause sits in the shared
-- `known()` helper and is tracked separately.
CREATE VIEW event_type_drift AS
SELECT
  batch_id,
  event_type_raw,
  COUNT(*) AS events
FROM events
WHERE event_type IS NULL AND event_type_raw IS NOT NULL
GROUP BY batch_id, event_type_raw;

-- No rollup view by event_type here on purpose: the friction/intervention
-- scorecard fields are issue #143's scope, and it owns their shape. This
-- migration only restores the columns those fields need.
