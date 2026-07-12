# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"
require "digest"

class StateContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "contracts", "state-schema-v2.json")
  FIXTURE_PATH = File.join(ROOT, "contracts", "fixtures", "v2", "lane_closed.json")
  ARCHIVE_SCHEMA_PATH = File.join(ROOT, "contracts", "archive-record-schema-v1.json")
  ARCHIVE_FIXTURE_PATH = File.join(ROOT, "contracts", "fixtures", "v1", "archive_record.json")
  COMPACTED_EVENTS_FIXTURE_PATH = File.join(ROOT, "contracts", "fixtures", "v1", "compacted_events.json")

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
end
