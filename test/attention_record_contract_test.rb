# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"

class AttentionRecordContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "schema", "state", "v1", "attention", "attention-record.schema.json")
  FIXTURES_PATH = File.join(ROOT, "schema", "state", "v1", "attention", "fixtures")

  def test_schema_publishes_workspace_scoped_attention_metadata
    schema = read_json(SCHEMA_PATH)

    assert JSONSchemer.valid_schema?(schema)
    assert_equal 1, schema.fetch("x-contract-version")
    assert_equal "attention", schema.fetch("x-record-family")
    assert_equal %w[workspace repository id], schema.fetch("x-logical-key")
    assert_equal "attention/{workspace}/{repository_owner}/{repository_name}/{id}.json",
                 schema.dig("x-storage-key", "template")
    properties = schema.dig("$defs", "attention_record", "properties")
    assert_equal 160, properties.dig("workspace", "maxLength")
    assert_equal 160, properties.dig("repository", "maxLength")
    assert_equal 160, properties.dig("id", "maxLength")
  end

  def test_valid_and_invalid_fixtures_define_the_record_contract
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))

    fixture_files("valid").each do |path|
      assert_empty schema.validate(read_json(path)).to_a, "expected valid fixture #{path} to conform"
    end
    fixture_files("invalid").each do |path|
      refute_empty schema.validate(read_json(path)).to_a, "expected invalid fixture #{path} to be rejected"
    end
  end

  def test_resolved_at_tracks_status
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    open_record = read_json(File.join(FIXTURES_PATH, "valid", "attention-open.json"))
    resolved_record = read_json(File.join(FIXTURES_PATH, "valid", "attention-resolved.json"))

    assert_empty schema.validate(open_record).to_a
    assert_empty schema.validate(resolved_record).to_a
    refute_empty schema.validate(open_record.merge("resolved_at" => open_record.fetch("refreshed_at"))).to_a
    refute_empty schema.validate(resolved_record.except("resolved_at")).to_a
  end

  def test_choices_and_safe_resume_are_bounded
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    record = read_json(File.join(FIXTURES_PATH, "valid", "attention-open.json"))

    refute_empty schema.validate(record.merge("choices" => Array.new(11, "choice"))).to_a
    refute_empty schema.validate(record.merge("safe_resume" => "x" * 4001)).to_a
  end

  def test_repository_storage_grammar_rejects_dot_aliases_but_allows_dot_prefixed_names
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    record = read_json(File.join(FIXTURES_PATH, "valid", "attention-open.json"))

    ["foo..bar/repo", "owner/foo..bar", "./foo", "repo/."].each do |repository|
      refute_empty schema.validate(record.merge("repository" => repository)).to_a,
                   "expected #{repository.inspect} to be rejected"
    end
    [".github/foo", "shakacode/.github"].each do |repository|
      assert_empty schema.validate(record.merge("repository" => repository)).to_a,
                   "expected #{repository.inspect} to conform"
    end
  end

  private

  def fixture_files(kind)
    Dir[File.join(FIXTURES_PATH, kind, "*.json")]
  end

  def read_json(path)
    JSON.parse(File.read(path, encoding: "UTF-8"))
  end
end
