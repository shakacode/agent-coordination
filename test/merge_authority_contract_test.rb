# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"

class MergeAuthorityContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "schema", "state", "v1", "merge-authority", "merge-authority.schema.json")
  FIXTURES_PATH = File.join(ROOT, "schema", "state", "v1", "merge-authority", "fixtures")
  # pr-batch launch vocabulary -> canonical persisted value.
  LAUNCH_TO_CANONICAL = { "auto_merge_when_gates_pass" => "auto", "ask" => "ask", "none" => "none" }.freeze

  def test_schema_publishes_the_merge_authority_contract_metadata
    schema_document = read_json(SCHEMA_PATH)

    assert JSONSchemer.valid_schema?(schema_document)
    assert_equal 1, schema_document.fetch("x-contract-version")
    assert_equal "merge_authority", schema_document.fetch("x-record-family")
    assert_equal "#/$defs/batch_manifest_projection", schema_document.fetch("$ref")
    assert_equal %w[none ask auto], schema_document.dig("$defs", "merge_authority", "enum")
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

  def test_merge_authority_value_accepts_only_canonical_short_forms
    schema = value_schema

    %w[none ask auto].each { |value| assert_empty schema.validate(value).to_a, "#{value} must conform" }
    ["auto_merge_when_gates_pass", "maybe", "Auto", "AUTO", "", nil, 1, true].each do |value|
      refute_empty schema.validate(value).to_a, "expected #{value.inspect} to be rejected"
    end
  end

  def test_launch_vocabulary_maps_onto_the_canonical_enum
    enum = read_json(SCHEMA_PATH).dig("$defs", "merge_authority", "enum")

    assert_equal %w[auto_merge_when_gates_pass ask none].sort, LAUNCH_TO_CANONICAL.keys.sort
    assert_empty(LAUNCH_TO_CANONICAL.values - enum, "every mapped value must be a canonical enum value")
    assert_equal "auto", LAUNCH_TO_CANONICAL.fetch("auto_merge_when_gates_pass")
  end

  def test_merge_authority_is_optional_but_never_null
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))

    assert_empty schema.validate({ "batch_id" => "b" }).to_a, "an omitted authority is the only undeclared form"
    refute_empty schema.validate({ "batch_id" => "b", "merge_authority" => nil }).to_a, "must be omitted, never null"
  end

  def test_drawer_replay_renders_value_or_em_dash
    replay = read_fixture(File.join(FIXTURES_PATH, "replay", "merge-authority-drawer.json"))
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))

    drawer = replay.fetch("batches").to_h do |batch|
      assert_empty schema.validate(batch).to_a, "replay batch #{batch['batch_id']} must conform"
      [batch.fetch("batch_id"), batch.fetch("merge_authority", "—")]
    end

    assert_equal replay.dig("expected", "drawer"), drawer
  end

  private

  def value_schema
    JSONSchemer.schema(read_json(SCHEMA_PATH).merge("$ref" => "#/$defs/merge_authority"))
  end

  def fixture_files(kind)
    Dir[File.join(FIXTURES_PATH, kind, "*.json")]
  end

  def read_fixture(path)
    read_json(path)
  end

  def read_json(path)
    JSON.parse(File.read(path, encoding: "UTF-8"))
  end
end
