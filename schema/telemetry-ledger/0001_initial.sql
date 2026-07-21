CREATE TABLE schema_migrations (
  version TEXT PRIMARY KEY,
  source_sha256 TEXT NOT NULL
);

CREATE TABLE source_artifacts (
  id INTEGER PRIMARY KEY,
  source_key TEXT NOT NULL UNIQUE,
  source_kind TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  source_sha256 TEXT NOT NULL
);

CREATE TABLE batches (
  batch_id TEXT PRIMARY KEY,
  repo TEXT,
  join_status TEXT NOT NULL,
  status TEXT,
  registered_at TEXT,
  updated_at TEXT,
  synthetic INTEGER NOT NULL CHECK (synthetic IN (0, 1)),
  source_kind TEXT NOT NULL,
  source_artifact_id INTEGER NOT NULL,
  source_record_sha256 TEXT NOT NULL,
  FOREIGN KEY (source_artifact_id) REFERENCES source_artifacts(id) ON DELETE CASCADE
);

CREATE TABLE lanes (
  batch_id TEXT NOT NULL,
  lane_id TEXT NOT NULL,
  owner_ref TEXT,
  status TEXT,
  host_family TEXT CHECK (host_family IN ('codex', 'claude') OR host_family IS NULL),
  session_ref TEXT,
  source_record_sha256 TEXT NOT NULL,
  PRIMARY KEY (batch_id, lane_id),
  FOREIGN KEY (batch_id) REFERENCES batches(batch_id) ON DELETE CASCADE
);

CREATE TABLE target_observations (
  id INTEGER PRIMARY KEY,
  batch_id TEXT NOT NULL,
  lane_id TEXT,
  repo TEXT,
  target TEXT,
  status TEXT,
  pr_url TEXT,
  join_status TEXT NOT NULL,
  source_record_sha256 TEXT NOT NULL,
  FOREIGN KEY (batch_id) REFERENCES batches(batch_id) ON DELETE CASCADE
);

CREATE TABLE target_units (
  id INTEGER PRIMARY KEY,
  batch_id TEXT NOT NULL,
  repo TEXT NOT NULL,
  target TEXT NOT NULL,
  join_status TEXT NOT NULL CHECK (join_status = 'exact'),
  outcome TEXT,
  outcome_evidence_status TEXT NOT NULL,
  pr_join_status TEXT NOT NULL,
  UNIQUE (batch_id, repo, target),
  FOREIGN KEY (batch_id) REFERENCES batches(batch_id) ON DELETE CASCADE
);

CREATE TABLE lane_memberships (
  target_unit_id INTEGER NOT NULL,
  lane_id TEXT NOT NULL,
  PRIMARY KEY (target_unit_id, lane_id),
  FOREIGN KEY (target_unit_id) REFERENCES target_units(id) ON DELETE CASCADE
);

CREATE TABLE claims (
  id INTEGER PRIMARY KEY,
  batch_id TEXT,
  repo TEXT,
  target TEXT,
  status TEXT,
  terminal TEXT,
  pr_url TEXT,
  join_status TEXT NOT NULL,
  source_artifact_id INTEGER NOT NULL,
  source_record_sha256 TEXT NOT NULL,
  FOREIGN KEY (source_artifact_id) REFERENCES source_artifacts(id) ON DELETE CASCADE
);

CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  event_ref TEXT NOT NULL,
  batch_id TEXT,
  repo TEXT,
  target TEXT,
  event_type TEXT,
  observed_at TEXT,
  terminal TEXT,
  join_status TEXT NOT NULL,
  source_artifact_id INTEGER NOT NULL,
  source_record_sha256 TEXT NOT NULL,
  FOREIGN KEY (source_artifact_id) REFERENCES source_artifacts(id) ON DELETE CASCADE
);

CREATE TABLE github_prs (
  id INTEGER PRIMARY KEY,
  repo TEXT NOT NULL,
  number INTEGER NOT NULL CHECK (number > 0),
  url TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('open', 'closed', 'merged')),
  created_at TEXT,
  merged_at TEXT,
  source_artifact_id INTEGER NOT NULL,
  source_record_sha256 TEXT NOT NULL,
  UNIQUE (repo, number),
  FOREIGN KEY (source_artifact_id) REFERENCES source_artifacts(id) ON DELETE CASCADE
);

CREATE TABLE target_pr_links (
  target_unit_id INTEGER NOT NULL,
  github_pr_id INTEGER NOT NULL,
  link_status TEXT NOT NULL CHECK (link_status IN ('exact', 'repo_mismatch')),
  source_record_sha256 TEXT NOT NULL,
  PRIMARY KEY (target_unit_id, github_pr_id),
  FOREIGN KEY (target_unit_id) REFERENCES target_units(id) ON DELETE CASCADE,
  FOREIGN KEY (github_pr_id) REFERENCES github_prs(id) ON DELETE CASCADE
);

CREATE VIEW outcome_scorecard AS
SELECT
  batch_id,
  COALESCE(outcome, 'UNKNOWN') AS outcome,
  COUNT(*) AS target_units
FROM target_units
GROUP BY batch_id, COALESCE(outcome, 'UNKNOWN');
