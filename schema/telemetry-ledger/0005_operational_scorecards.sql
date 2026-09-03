-- Issue #143: operational load scorecard inputs.
--
-- Keep the raw integer counts in SQLite. The scorecard renderer owns the
-- per-ten normalization so a zero merged-PR denominator can remain explicitly
-- UNKNOWN instead of being misreported as zero.

CREATE VIEW operational_event_scorecard AS
SELECT
  batches.batch_id,
  (
    SELECT COUNT(DISTINCT github_prs.id)
    FROM target_units
    JOIN target_pr_links ON target_pr_links.target_unit_id = target_units.id
    JOIN github_prs ON github_prs.id = target_pr_links.github_pr_id
    WHERE target_units.batch_id = batches.batch_id
      AND target_pr_links.link_status = 'exact'
      AND github_prs.state = 'merged'
  ) AS merged_prs,
  COALESCE(SUM(CASE WHEN events.event_type = 'human_intervention' THEN 1 ELSE 0 END), 0)
    AS human_interventions,
  COALESCE(SUM(CASE WHEN events.event_type = 'human_intervention' AND events.kind = 'takeover'
                    THEN 1 ELSE 0 END), 0) AS intervention_takeover,
  COALESCE(SUM(CASE WHEN events.event_type = 'human_intervention' AND events.kind = 'supersede'
                    THEN 1 ELSE 0 END), 0) AS intervention_supersede,
  COALESCE(SUM(CASE WHEN events.event_type = 'human_intervention' AND events.kind = 'manual-fix'
                    THEN 1 ELSE 0 END), 0) AS intervention_manual_fix,
  COALESCE(SUM(CASE WHEN events.event_type = 'human_intervention' AND events.kind = 'drain'
                    THEN 1 ELSE 0 END), 0) AS intervention_drain,
  COALESCE(SUM(CASE WHEN events.event_type = 'help_requested' THEN 1 ELSE 0 END), 0)
    AS help_requests,
  COALESCE(SUM(CASE WHEN events.event_type = 'help_requested' AND events.reason = 'blocked-user-input'
                    THEN 1 ELSE 0 END), 0) AS help_blocked_user_input,
  COALESCE(SUM(CASE WHEN events.event_type = 'help_requested' AND events.reason = 'question'
                    THEN 1 ELSE 0 END), 0) AS help_question,
  COALESCE(SUM(CASE WHEN events.event_type = 'help_requested' AND events.reason = 'permission'
                    THEN 1 ELSE 0 END), 0) AS help_permission,
  COALESCE(SUM(CASE WHEN events.event_type = 'escalation_requested' THEN 1 ELSE 0 END), 0)
    AS escalations
FROM batches
LEFT JOIN events ON events.batch_id = batches.batch_id
GROUP BY batches.batch_id;

-- A target supplies a lane duration only when the lane names exactly one
-- target and that target belongs to exactly one lane. Shared or targetless
-- membership is not silently duplicated; it remains a telemetry gap.
CREATE VIEW lane_duration_scorecard AS
WITH lane_targets AS (
  SELECT
    lanes.batch_id,
    lanes.lane_id,
    COUNT(target_units.id) AS target_count,
    MIN(target_units.id) AS target_unit_id
  FROM lanes
  LEFT JOIN lane_memberships
    ON lane_memberships.lane_id = lanes.lane_id
  LEFT JOIN target_units
    ON target_units.id = lane_memberships.target_unit_id
   AND target_units.batch_id = lanes.batch_id
  GROUP BY lanes.batch_id, lanes.lane_id
),
target_lane_counts AS (
  SELECT target_unit_id, COUNT(*) AS lane_count
  FROM lane_memberships
  GROUP BY target_unit_id
),
eligible_lane_targets AS (
  SELECT lane_targets.batch_id, lane_targets.lane_id, target_units.repo, target_units.target
  FROM lane_targets
  JOIN target_lane_counts
    ON target_lane_counts.target_unit_id = lane_targets.target_unit_id
  JOIN target_units
    ON target_units.id = lane_targets.target_unit_id
  WHERE lane_targets.target_count = 1
    AND target_lane_counts.lane_count = 1
),
claim_starts AS (
  SELECT
    eligible_lane_targets.batch_id,
    eligible_lane_targets.lane_id,
    MIN(unixepoch(events.observed_at)) AS claim_started_at
  FROM eligible_lane_targets
  LEFT JOIN events
    ON events.batch_id = eligible_lane_targets.batch_id
   AND events.repo = eligible_lane_targets.repo
   AND events.target = eligible_lane_targets.target
   AND events.join_status = 'exact'
   AND events.event_type = 'claim.acquired'
  GROUP BY eligible_lane_targets.batch_id, eligible_lane_targets.lane_id
),
terminal_events AS (
  SELECT
    claim_starts.batch_id,
    claim_starts.lane_id,
    claim_starts.claim_started_at,
    MIN(unixepoch(events.observed_at)) AS terminal_at
  FROM claim_starts
  JOIN eligible_lane_targets
    ON eligible_lane_targets.batch_id = claim_starts.batch_id
   AND eligible_lane_targets.lane_id = claim_starts.lane_id
  LEFT JOIN events
    ON events.batch_id = eligible_lane_targets.batch_id
   AND events.repo = eligible_lane_targets.repo
   AND events.target = eligible_lane_targets.target
   AND events.join_status = 'exact'
   AND (
     events.event_type = 'claim.released'
     OR (
       events.event_type = 'lane_closed'
       AND events.terminal IN ('done', 'abandoned', 'superseded')
     )
   )
   AND unixepoch(events.observed_at) > claim_starts.claim_started_at
  GROUP BY claim_starts.batch_id, claim_starts.lane_id, claim_starts.claim_started_at
)
SELECT
  lanes.batch_id,
  lanes.lane_id,
  CASE
    WHEN terminal_events.claim_started_at IS NULL OR terminal_events.terminal_at IS NULL THEN NULL
    ELSE terminal_events.terminal_at - terminal_events.claim_started_at
  END AS duration_seconds
FROM lanes
LEFT JOIN terminal_events
  ON terminal_events.batch_id = lanes.batch_id
 AND terminal_events.lane_id = lanes.lane_id;

-- A reclaim is a claim acquisition immediately after a release or explicit
-- takeover in the same batch/repository/target custody sequence. Consecutive
-- claim acquisitions are renewals or generation changes, not repeated rework.
CREATE VIEW custody_rework_scorecard AS
WITH custody_events AS (
  SELECT
    events.id,
    events.batch_id,
    events.repo,
    events.target,
    events.observed_at,
    CASE
      WHEN events.event_type = 'human_intervention' THEN 'takeover'
      ELSE events.event_type
    END AS custody_type
  FROM events
  WHERE events.join_status = 'exact'
    AND unixepoch(events.observed_at) IS NOT NULL
    AND (
      events.event_type IN ('claim.acquired', 'claim.released')
      OR (events.event_type = 'human_intervention' AND events.kind = 'takeover')
    )
),
sequenced AS (
  SELECT
    custody_events.*,
    LAG(custody_type) OVER (
      PARTITION BY batch_id, repo, target
      ORDER BY unixepoch(observed_at), id
    ) AS prior_custody_type
  FROM custody_events
)
SELECT
  batches.batch_id,
  COALESCE(SUM(CASE
    WHEN sequenced.custody_type = 'claim.acquired'
      AND sequenced.prior_custody_type IN ('claim.released', 'takeover')
    THEN 1 ELSE 0 END), 0) AS reclaims
FROM batches
LEFT JOIN sequenced ON sequenced.batch_id = batches.batch_id
GROUP BY batches.batch_id;
