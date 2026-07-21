CREATE TABLE pricing_snapshots (
  snapshot_id TEXT PRIMARY KEY,
  version INTEGER NOT NULL CHECK (version > 0),
  currency TEXT NOT NULL CHECK (currency = 'USD'),
  published_at TEXT NOT NULL,
  source_sha256 TEXT NOT NULL
);

CREATE TABLE pricing_rates (
  snapshot_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  profile TEXT NOT NULL,
  component TEXT NOT NULL CHECK (component IN ('input', 'cache_read', 'cache_write', 'output', 'reasoning_output')),
  rate_microusd_per_million_tokens INTEGER NOT NULL CHECK (rate_microusd_per_million_tokens >= 0),
  long_context_threshold_input_tokens INTEGER,
  input_multiplier_numerator INTEGER NOT NULL,
  input_multiplier_denominator INTEGER NOT NULL,
  output_multiplier_numerator INTEGER NOT NULL,
  output_multiplier_denominator INTEGER NOT NULL,
  PRIMARY KEY (snapshot_id, model, profile, component),
  FOREIGN KEY (snapshot_id) REFERENCES pricing_snapshots(snapshot_id) ON DELETE CASCADE
);

ALTER TABLE usage_calls ADD COLUMN pricing_snapshot_id TEXT;
ALTER TABLE usage_calls ADD COLUMN pricing_status TEXT NOT NULL DEFAULT 'unknown'
  CHECK (pricing_status IN ('priced', 'unknown'));
ALTER TABLE usage_calls ADD COLUMN total_cost_microusd INTEGER
  CHECK (total_cost_microusd >= 0 OR total_cost_microusd IS NULL);

CREATE TABLE usage_cost_components (
  usage_call_id INTEGER NOT NULL,
  component TEXT NOT NULL,
  tokens INTEGER NOT NULL CHECK (tokens >= 0),
  rate_microusd_per_million_tokens INTEGER NOT NULL CHECK (rate_microusd_per_million_tokens >= 0),
  multiplier_numerator INTEGER NOT NULL CHECK (multiplier_numerator > 0),
  multiplier_denominator INTEGER NOT NULL CHECK (multiplier_denominator > 0),
  cost_microusd INTEGER NOT NULL CHECK (cost_microusd >= 0),
  PRIMARY KEY (usage_call_id, component),
  FOREIGN KEY (usage_call_id) REFERENCES usage_calls(id) ON DELETE CASCADE
);

CREATE TABLE allocated_costs (
  target_unit_id INTEGER NOT NULL,
  host_session_id INTEGER NOT NULL,
  pricing_snapshot_id TEXT,
  pricing_status TEXT NOT NULL CHECK (pricing_status IN ('priced', 'unknown')),
  cost_microusd INTEGER CHECK (cost_microusd >= 0 OR cost_microusd IS NULL),
  PRIMARY KEY (target_unit_id, host_session_id),
  FOREIGN KEY (target_unit_id) REFERENCES target_units(id) ON DELETE CASCADE,
  FOREIGN KEY (host_session_id) REFERENCES host_sessions(id) ON DELETE CASCADE
);

CREATE TABLE review_receipts (
  id INTEGER PRIMARY KEY,
  github_pr_id INTEGER NOT NULL,
  target_unit_id INTEGER,
  review_ref TEXT NOT NULL,
  model TEXT,
  effort TEXT,
  pricing_profile TEXT,
  input_tokens INTEGER CHECK (input_tokens >= 0 OR input_tokens IS NULL),
  cache_read_tokens INTEGER CHECK (cache_read_tokens >= 0 OR cache_read_tokens IS NULL),
  cache_write_tokens INTEGER CHECK (cache_write_tokens >= 0 OR cache_write_tokens IS NULL),
  output_tokens INTEGER CHECK (output_tokens >= 0 OR output_tokens IS NULL),
  reasoning_output_tokens INTEGER CHECK (reasoning_output_tokens >= 0 OR reasoning_output_tokens IS NULL),
  total_tokens INTEGER CHECK (total_tokens >= 0 OR total_tokens IS NULL),
  pricing_snapshot_id TEXT,
  pricing_status TEXT NOT NULL CHECK (pricing_status IN ('priced', 'unknown')),
  cost_microusd INTEGER CHECK (cost_microusd >= 0 OR cost_microusd IS NULL),
  source_record_sha256 TEXT NOT NULL,
  UNIQUE (github_pr_id, review_ref),
  FOREIGN KEY (github_pr_id) REFERENCES github_prs(id) ON DELETE CASCADE,
  FOREIGN KEY (target_unit_id) REFERENCES target_units(id) ON DELETE SET NULL
);

CREATE TABLE review_findings (
  id INTEGER PRIMARY KEY,
  review_receipt_id INTEGER NOT NULL,
  finding_ref TEXT NOT NULL,
  severity TEXT CHECK (severity IN ('P0', 'P1', 'P2', 'P3') OR severity IS NULL),
  disposition TEXT,
  verification_status TEXT,
  source_record_sha256 TEXT NOT NULL,
  UNIQUE (review_receipt_id, finding_ref),
  FOREIGN KEY (review_receipt_id) REFERENCES review_receipts(id) ON DELETE CASCADE
);

CREATE VIEW cost_scorecard AS
SELECT
  batches.batch_id,
  COALESCE(SUM(CASE WHEN allocated_costs.pricing_status = 'priced' THEN allocated_costs.cost_microusd ELSE 0 END), 0)
    AS known_cost_microusd,
  COUNT(allocated_costs.host_session_id) AS allocated_sessions,
  COALESCE(SUM(CASE WHEN allocated_costs.pricing_status = 'unknown' THEN 1 ELSE 0 END), 0)
    AS unknown_cost_sessions
FROM batches
LEFT JOIN target_units ON target_units.batch_id = batches.batch_id
LEFT JOIN allocated_costs ON allocated_costs.target_unit_id = target_units.id
GROUP BY batches.batch_id;

CREATE VIEW review_economics_scorecard AS
SELECT
  batches.batch_id,
  (
    SELECT COUNT(*) FROM review_receipts
    JOIN target_units ON target_units.id = review_receipts.target_unit_id
    WHERE target_units.batch_id = batches.batch_id
  ) AS reviews,
  (
    SELECT COUNT(*) FROM review_findings
    JOIN review_receipts ON review_receipts.id = review_findings.review_receipt_id
    JOIN target_units ON target_units.id = review_receipts.target_unit_id
    WHERE target_units.batch_id = batches.batch_id
  ) AS findings,
  (
    SELECT COUNT(*) FROM review_findings
    JOIN review_receipts ON review_receipts.id = review_findings.review_receipt_id
    JOIN target_units ON target_units.id = review_receipts.target_unit_id
    WHERE target_units.batch_id = batches.batch_id
      AND review_findings.disposition = 'should_fix'
  ) AS actionable_findings,
  COALESCE((
    SELECT SUM(review_receipts.cost_microusd) FROM review_receipts
    JOIN target_units ON target_units.id = review_receipts.target_unit_id
    WHERE target_units.batch_id = batches.batch_id
      AND review_receipts.pricing_status = 'priced'
  ), 0) AS known_review_cost_microusd,
  (
    SELECT COUNT(*) FROM review_receipts
    JOIN target_units ON target_units.id = review_receipts.target_unit_id
    WHERE target_units.batch_id = batches.batch_id
      AND review_receipts.pricing_status = 'unknown'
  ) AS unknown_review_costs,
  CASE
    WHEN (
      SELECT COUNT(*) FROM review_receipts
      JOIN target_units ON target_units.id = review_receipts.target_unit_id
      WHERE target_units.batch_id = batches.batch_id
        AND review_receipts.pricing_status = 'unknown'
    ) > 0 THEN NULL
    WHEN (
      SELECT COUNT(*) FROM review_findings
      JOIN review_receipts ON review_receipts.id = review_findings.review_receipt_id
      JOIN target_units ON target_units.id = review_receipts.target_unit_id
      WHERE target_units.batch_id = batches.batch_id
        AND review_findings.disposition = 'should_fix'
    ) = 0 THEN NULL
    ELSE (
      SELECT SUM(review_receipts.cost_microusd) FROM review_receipts
      JOIN target_units ON target_units.id = review_receipts.target_unit_id
      WHERE target_units.batch_id = batches.batch_id
        AND review_receipts.pricing_status = 'priced'
    ) / (
      SELECT COUNT(*) FROM review_findings
      JOIN review_receipts ON review_receipts.id = review_findings.review_receipt_id
      JOIN target_units ON target_units.id = review_receipts.target_unit_id
      WHERE target_units.batch_id = batches.batch_id
        AND review_findings.disposition = 'should_fix'
    )
  END AS cost_per_actionable_finding_microusd
FROM batches;
