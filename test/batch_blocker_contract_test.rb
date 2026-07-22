# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"

class BatchBlockerContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "schema", "state", "v1", "batch-blocker", "batch-blocker.schema.json")
  FIXTURES_PATH = File.join(ROOT, "schema", "state", "v1", "batch-blocker", "fixtures")

  def test_schema_publishes_the_batch_blocker_contract_metadata
    schema_document = read_json(SCHEMA_PATH)

    assert JSONSchemer.valid_schema?(schema_document)
    assert_equal 1, schema_document.fetch("x-contract-version")
    assert_equal "batch_blocker", schema_document.fetch("x-record-family")
    assert_equal %w[workspace batch_id], schema_document.fetch("x-logical-key")
    assert_equal "batch_blockers/{workspace}/{batch_id}.json", schema_document.dig("x-storage-key", "template")
    assert_equal "default", schema_document.dig("$defs", "workspace", "default")
  end

  def test_positive_and_negative_fixtures_conform_to_v1_contract
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))

    fixture_files("valid").each do |path|
      assert_empty schema.validate(read_fixture(path)).to_a, "expected valid fixture #{path} to conform"
    end
    fixture_files("invalid").each do |path|
      refute_empty schema.validate(read_fixture(path)).to_a, "expected invalid fixture #{path} to be rejected"
    end
  end

  def test_recommended_reply_is_optional_but_never_null_or_empty
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    record = read_fixture(File.join(FIXTURES_PATH, "valid", "blocker-full.json"))

    assert_empty schema.validate(record).to_a
    assert_empty schema.validate(with_blocker(record, without(record.fetch("blocker"), "recommendedReply"))).to_a
    refute_empty schema.validate(with_blocker(record, record.fetch("blocker").merge("recommendedReply" => nil))).to_a
    refute_empty schema.validate(with_blocker(record, record.fetch("blocker").merge("recommendedReply" => ""))).to_a
  end

  def test_decisions_must_be_a_non_empty_list_of_non_empty_strings
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    record = read_fixture(File.join(FIXTURES_PATH, "valid", "blocker-full.json"))

    refute_empty schema.validate(with_blocker(record, record.fetch("blocker").merge("decisions" => []))).to_a
    refute_empty schema.validate(with_blocker(record, record.fetch("blocker").merge("decisions" => [""]))).to_a
    refute_empty schema.validate(with_blocker(record, record.fetch("blocker").merge("decisions" => [1]))).to_a
  end

  def test_workspace_is_required_in_the_logical_key
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    record = read_fixture(File.join(FIXTURES_PATH, "valid", "blocker-full.json"))

    refute_empty schema.validate(without(record, "workspace")).to_a,
                 "workspace is a first-class key dimension (ADR 0004)"
  end

  def test_panel_replay_renders_message_decisions_and_optional_reply
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    replay = read_fixture(File.join(FIXTURES_PATH, "replay", "blocker-panel-render.json"))

    replay.fetch("records").each do |entry|
      record = entry.fetch("record")
      assert_empty schema.validate(record).to_a, "replay record must conform"
      assert_equal entry.fetch("expected_panel"), render_panel(record.fetch("blocker"))
    end
  end

  private

  def fixture_files(kind)
    Dir[File.join(FIXTURES_PATH, kind, "*.json")]
  end

  def read_fixture(path)
    read_json(path)
  end

  def read_json(path)
    JSON.parse(File.read(path, encoding: "UTF-8"))
  end

  def without(hash, key)
    hash.reject { |name, _| name == key }
  end

  def with_blocker(record, blocker)
    record.merge("blocker" => blocker)
  end

  # An absent recommendedReply renders as a hidden (nil) reply on the panel.
  def render_panel(blocker)
    {
      "message" => blocker.fetch("message"),
      "decisions" => blocker.fetch("decisions"),
      "recommendedReply" => blocker["recommendedReply"]
    }
  end
end
