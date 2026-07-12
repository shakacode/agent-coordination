# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"
require "digest"
require "time"

class StateContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "contracts", "state-schema-v2.json")
  FIXTURE_PATH = File.join(ROOT, "contracts", "fixtures", "v2", "lane_closed.json")
  ARCHIVE_SCHEMA_PATH = File.join(ROOT, "contracts", "archive-record-schema-v1.json")
  ARCHIVE_FIXTURE_PATH = File.join(ROOT, "contracts", "fixtures", "v1", "archive_record.json")
  COMPACTED_EVENTS_FIXTURE_PATH = File.join(ROOT, "contracts", "fixtures", "v1", "compacted_events.json")
  HOST_LIMIT_SCHEMA_PATH = File.join(ROOT, "schema", "state", "v1", "host-limit.schema.json")
  HOST_LIMIT_FIXTURES_PATH = File.join(ROOT, "schema", "state", "v1", "fixtures")

  def test_lane_closed_fixture_conforms_to_published_v2_contract
    schema_document = JSON.parse(File.read(SCHEMA_PATH))
    fixture = JSON.parse(File.read(FIXTURE_PATH))
    schema = JSONSchemer.schema(schema_document)

    assert_equal 2, schema_document.fetch("x-contract-version")
    assert_equal "default", schema_document.fetch("$defs").fetch("workspace").fetch("default")
    assert_equal "lane_closed-0f5a0caebfed6139", fixture.fetch("event_id")
    expected = "lane_closed-#{Digest::SHA256.hexdigest(fixture.fetch('lane'))[0, 16]}"
    assert_equal expected, fixture.fetch("event_id")
    assert_match(/\Alane_closed-[0-9a-f]{16}\z/, fixture.fetch("event_id"))
    assert_empty schema.validate(fixture).to_a
  end

  def test_archive_fixture_conforms_to_published_v1_contract
    schema_document = JSON.parse(File.read(ARCHIVE_SCHEMA_PATH))
    schema = JSONSchemer.schema(schema_document)
    fixtures = [ARCHIVE_FIXTURE_PATH, COMPACTED_EVENTS_FIXTURE_PATH].map { |path| JSON.parse(File.read(path)) }

    assert_equal 1, schema_document.fetch("x-contract-version")
    assert_equal "archive", schema_document.fetch("x-record-family")
    fixtures.each { |fixture| assert_empty schema.validate(fixture).to_a }
    compacted = fixtures.fetch(1)
    assert_operator compacted.fetch("source_paths").length, :>, compacted.fetch("records").length
    lane_closed = compacted.fetch("records").find { |record| record["type"] == "lane_closed" }
    state_schema = JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH)))
    assert_empty state_schema.validate(lane_closed).to_a
  end

  def test_lane_closed_contract_rejects_missing_workspace_and_invalid_terminal
    schema = JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH)))
    fixture = JSON.parse(File.read(FIXTURE_PATH))
    fixture.delete("workspace")
    fixture["terminal"] = "finished"

    errors = schema.validate(fixture).to_a

    refute_empty errors
    error_pointers = errors.map { |error| error.fetch("data_pointer") }
    assert_includes error_pointers, ""
    assert_includes error_pointers, "/terminal"
  end

  def test_host_limit_positive_and_negative_fixtures_conform_to_v1_contract
    schema_document = JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH))
    schema = JSONSchemer.schema(schema_document)

    assert JSONSchemer.valid_schema?(schema_document)
    assert_equal 1, schema_document.fetch("x-contract-version")
    assert_equal "host_limit", schema_document.fetch("x-record-family")
    assert_equal %w[workspace machine quota_host scope], schema_document.fetch("x-logical-key")
    assert_equal "host_limits/{workspace}/{machine}/{quota_host}/{scope}.json",
                 schema_document.dig("x-storage-key", "template")
    assert_equal %w[workspace machine quota_host scope],
                 schema_document.dig("$defs", "status_projection", "properties", "host_limits", "x-unique-key")
    assert_equal "producer",
                 schema_document.dig(
                   "$defs", "status_projection", "properties", "host_limits", "x-unique-key-enforcement"
                 )
    assert_equal "default", schema_document.dig("$defs", "workspace", "default")

    fixture_files("valid").each do |path|
      assert_empty schema.validate(read_fixture(path)).to_a, "expected valid fixture #{path} to conform"
    end
    fixture_files("invalid").each do |path|
      refute_empty schema.validate(read_fixture(path)).to_a, "expected invalid fixture #{path} to be rejected"
    end
  end

  def test_host_limit_contract_rejects_invalid_key_and_state_variants
    schema = JSONSchemer.schema(JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH)))
    fixture = read_fixture(fixture_files("valid").first)

    variants = [
      fixture.except("workspace"),
      fixture.except("quota_host").merge("host" => "claude-code/conductor"),
      fixture.merge("schema_version" => 2),
      fixture.merge("status" => "expired"),
      fixture.merge("source" => "private-api"),
      fixture.merge("scope" => "Five Hour"),
      fixture.merge("unexpected" => true)
    ]

    variants.each { |variant| refute_empty schema.validate(variant).to_a }
  end

  def test_host_limit_source_vocabulary_and_canonical_quota_host_rules
    schema = JSONSchemer.schema(JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH)))
    fixture = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "valid", "host-limit-active.json"))

    %w[manual host-message hook probe].each do |source|
      assert_empty schema.validate(fixture.merge("source" => source)).to_a
    end
    ["Quota-Host-A", " quota-host-a", "quota host a", "https://quota-host-a", "quota-host-a:443"].each do |host|
      refute_empty schema.validate(fixture.merge("quota_host" => host)).to_a
    end
  end

  def test_two_lanes_replay_one_effective_host_limit_record
    schema_document = JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH))
    projection_schema = JSONSchemer.schema(schema_document.merge("$ref" => "#/$defs/status_projection"))
    replay = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "replay", "two-lanes-one-host-limit.json"))
    records = replay.dig("status", "host_limits")

    assert_empty projection_schema.validate(replay.fetch("status")).to_a
    assert_equal %w[batches claims events heartbeats host_limits], replay.fetch("status").keys.sort
    assert(replay.fetch("lanes").all? { |lane| lane.fetch("host") != lane.fetch("quota_host") })
    assert_equal records.length, records.map { |record| logical_key(record) }.uniq.length

    effective = effective_host_limits(records, replay.fetch("as_of"))
    lane_statuses = replay.fetch("lanes").to_h do |lane|
      blocked = effective.any? do |record|
        %w[workspace machine quota_host].all? { |key| lane.fetch(key) == record.fetch(key) }
      end
      [lane.fetch("lane"), blocked ? "blocked-on-limit" : "available"]
    end

    assert_equal replay.dig("expected", "effective_record_count"), effective.length
    assert_equal replay.dig("expected", "lane_statuses"), lane_statuses
  end

  def test_status_projection_excludes_cleared_and_elapsed_reset_records
    active = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "valid", "host-limit-active.json"))
    cleared = read_fixture(File.join(HOST_LIMIT_FIXTURES_PATH, "valid", "host-limit-cleared.json"))
    unknown_reset = active.merge("scope" => "weekly", "resets_at" => nil)

    assert_equal [unknown_reset], effective_host_limits(
      [active, cleared, unknown_reset],
      "2026-07-13T01:00:00Z"
    )
  end

  def test_status_projection_procedurally_rejects_duplicate_logical_keys
    schema_document = JSON.parse(File.read(HOST_LIMIT_SCHEMA_PATH))
    projection_schema = JSONSchemer.schema(schema_document.merge("$ref" => "#/$defs/status_projection"))
    fixture = read_fixture(
      File.join(HOST_LIMIT_FIXTURES_PATH, "procedural", "host-limits-duplicate-logical-key.json")
    )

    assert_empty projection_schema.validate(fixture).to_a,
                 "JSON Schema validates the records but cannot enforce composite-key uniqueness"
    assert_equal(%w[active cleared], fixture.fetch("host_limits").map { |record| record.fetch("status") })
    assert_raises(ArgumentError) { enforce_unique_logical_keys!(fixture.fetch("host_limits")) }
  end

  private

  def fixture_files(kind)
    Dir[File.join(HOST_LIMIT_FIXTURES_PATH, kind, "*.json")]
  end

  def read_fixture(path)
    JSON.parse(File.read(path))
  end

  def logical_key(record)
    %w[workspace machine quota_host scope].map { |field| record.fetch(field) }
  end

  def enforce_unique_logical_keys!(records)
    duplicates = records.group_by { |record| logical_key(record) }.select { |_, matches| matches.length > 1 }
    raise ArgumentError, "duplicate host-limit logical key" unless duplicates.empty?
  end

  def effective_host_limits(records, as_of)
    projection_time = Time.iso8601(as_of)
    records.select do |record|
      next false unless record.fetch("status") == "active"

      resets_at = record.fetch("resets_at")
      resets_at.nil? || Time.iso8601(resets_at) > projection_time
    end
  end
end
