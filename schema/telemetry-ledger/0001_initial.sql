CREATE TABLE schema_migrations (
  version TEXT PRIMARY KEY,
  source_sha256 TEXT NOT NULL
);

CREATE TABLE batches (
  batch_id TEXT PRIMARY KEY,
  repo TEXT NOT NULL,
  status TEXT NOT NULL,
  registered_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  synthetic INTEGER NOT NULL CHECK (synthetic IN (0, 1)),
  source_kind TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  source_record_id TEXT NOT NULL,
  source_sha256 TEXT NOT NULL
);

CREATE TABLE target_units (
  batch_id TEXT NOT NULL,
  repo TEXT NOT NULL,
  target TEXT NOT NULL,
  lane_count INTEGER NOT NULL CHECK (lane_count > 0),
  lanes_json TEXT NOT NULL,
  outcome TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  source_record_id TEXT NOT NULL,
  source_sha256 TEXT NOT NULL,
  PRIMARY KEY (batch_id, repo, target),
  FOREIGN KEY (batch_id) REFERENCES batches(batch_id) ON DELETE CASCADE
);
