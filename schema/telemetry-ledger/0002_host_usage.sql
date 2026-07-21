CREATE TABLE ingestion_errors (
  id INTEGER PRIMARY KEY,
  source_artifact_id INTEGER NOT NULL,
  record_ordinal INTEGER NOT NULL CHECK (record_ordinal > 0),
  reason TEXT NOT NULL CHECK (reason IN ('invalid_json', 'invalid_record')),
  UNIQUE (source_artifact_id, record_ordinal, reason),
  FOREIGN KEY (source_artifact_id) REFERENCES source_artifacts(id) ON DELETE CASCADE
);

CREATE TABLE host_sessions (
  id INTEGER PRIMARY KEY,
  host_family TEXT NOT NULL CHECK (host_family IN ('codex', 'claude')),
  session_ref TEXT NOT NULL,
  cwd_basename TEXT,
  cwd_sha256 TEXT,
  model TEXT,
  effort TEXT,
  pricing_profile TEXT,
  link_status TEXT NOT NULL CHECK (link_status IN ('unmatched', 'ambiguous', 'exact')),
  source_artifact_id INTEGER NOT NULL,
  source_record_sha256 TEXT NOT NULL,
  UNIQUE (source_artifact_id, session_ref),
  FOREIGN KEY (source_artifact_id) REFERENCES source_artifacts(id) ON DELETE CASCADE
);

CREATE TABLE session_lane_links (
  host_session_id INTEGER PRIMARY KEY,
  target_unit_id INTEGER NOT NULL,
  lane_id TEXT NOT NULL,
  link_status TEXT NOT NULL CHECK (link_status = 'exact'),
  FOREIGN KEY (host_session_id) REFERENCES host_sessions(id) ON DELETE CASCADE,
  FOREIGN KEY (target_unit_id) REFERENCES target_units(id) ON DELETE CASCADE
);

CREATE TABLE usage_calls (
  id INTEGER PRIMARY KEY,
  host_session_id INTEGER NOT NULL,
  source_artifact_id INTEGER NOT NULL,
  record_ordinal INTEGER NOT NULL CHECK (record_ordinal > 0),
  model TEXT,
  effort TEXT,
  pricing_profile TEXT,
  input_tokens INTEGER CHECK (input_tokens >= 0 OR input_tokens IS NULL),
  cache_read_tokens INTEGER CHECK (cache_read_tokens >= 0 OR cache_read_tokens IS NULL),
  cache_write_tokens INTEGER CHECK (cache_write_tokens >= 0 OR cache_write_tokens IS NULL),
  output_tokens INTEGER CHECK (output_tokens >= 0 OR output_tokens IS NULL),
  reasoning_output_tokens INTEGER CHECK (reasoning_output_tokens >= 0 OR reasoning_output_tokens IS NULL),
  total_tokens INTEGER CHECK (total_tokens >= 0 OR total_tokens IS NULL),
  source_record_sha256 TEXT NOT NULL,
  UNIQUE (source_artifact_id, record_ordinal),
  FOREIGN KEY (host_session_id) REFERENCES host_sessions(id) ON DELETE CASCADE,
  FOREIGN KEY (source_artifact_id) REFERENCES source_artifacts(id) ON DELETE CASCADE
);
