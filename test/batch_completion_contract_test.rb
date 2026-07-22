# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"

class BatchCompletionContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "schema", "state", "v1", "batch-completion", "batch-completion.schema.json")
  FIXTURES_PATH = File.join(ROOT, "schema", "state", "v1", "batch-completion", "fixtures")

  def test_schema_publishes_the_batch_completion_contract_metadata
    schema_document = read_json(SCHEMA_PATH)

    assert JSONSchemer.valid_schema?(schema_document)
    assert_equal 1, schema_document.fetch("x-contract-version")
    assert_equal "batch_completion", schema_document.fetch("x-record-family")
    assert_equal %w[batch_id], schema_document.fetch("x-logical-key")
    assert_equal "batch_completions/{batch_id}.json", schema_document.dig("x-storage-key", "template")
    assert_equal %w[clean findings pending], schema_document.dig("$defs", "audit", "properties", "verdict", "enum")
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

  def test_archive_ready_requires_state_live_audit_and_receipts
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    minimal = read_fixture(File.join(FIXTURES_PATH, "valid", "completion-minimal-archive-ready.json"))

    assert_empty schema.validate(minimal).to_a
    refute_empty schema.validate(without(minimal, "audit")).to_a
    refute_empty schema.validate(deep_without(minimal, "completion", "receipts")).to_a
    live_removed = minimal.dup
    live_removed["completion"] = minimal.fetch("completion").merge("state" => { "replay" => "—" })
    refute_empty schema.validate(live_removed).to_a
  end

  def test_optional_metrics_never_omitted_or_fabricated
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    record = read_fixture(File.join(FIXTURES_PATH, "valid", "completion-full.json"))

    %w[tokensTotal cost].each do |metric|
      assert_empty schema.validate(with_metric(record, metric, nil)).to_a, "null #{metric} conforms"
      assert_empty schema.validate(with_metric(record, metric, "—")).to_a, "em dash #{metric} conforms"
      refute_empty schema.validate(with_metric(record, metric, "lots")).to_a, "fabricated string #{metric} rejected"
      refute_empty schema.validate(drop_metric(record, metric)).to_a, "omitted #{metric} rejected"
    end
    refute_empty schema.validate(with_metric(record, "tokensTotal", -1)).to_a
  end

  def test_audit_has_no_separate_version_field
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    record = read_fixture(File.join(FIXTURES_PATH, "valid", "completion-full.json"))
    record["audit"] = record.fetch("audit").merge("version" => "v1")

    refute_empty schema.validate(record).to_a, "audit folds version into author; a separate version field is rejected"
  end

  def test_drawer_render_replay_matches_expected
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    replay = read_fixture(File.join(FIXTURES_PATH, "replay", "completion-drawer-render.json"))
    record = replay.fetch("record")
    expected = replay.fetch("expected")

    assert_empty schema.validate(record).to_a, "replay record must conform"
    assert_equal expected.fetch("audit_chip"), record.fetch("audit")
    assert_equal expected.fetch("final_report"), record.fetch("finalReport")
    assert_equal expected.fetch("outcome_rows"), render_outcomes(record.dig("completion", "outcomes"))
    assert_equal expected.fetch("rendered_metrics"), render_metrics(record.fetch("completion"))
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

  def without(record, key)
    record.reject { |name, _| name == key }
  end

  def deep_without(record, outer, inner)
    record.merge(outer => without(record.fetch(outer), inner))
  end

  def with_metric(record, metric, value)
    record.merge("completion" => record.fetch("completion").merge(metric => value))
  end

  def drop_metric(record, metric)
    record.merge("completion" => without(record.fetch("completion"), metric))
  end

  # The dashboard renders a null or em-dash metric as "—", and passes known values through.
  def render_metrics(completion)
    %w[usage tokensTotal cost duration].to_h do |metric|
      value = completion.fetch(metric)
      [metric, value.nil? ? "—" : value]
    end
  end

  def render_outcomes(outcomes)
    outcomes.map do |outcome|
      {
        "lane" => outcome.fetch("lane"),
        "refs" => outcome["refs"],
        "link_labels" => (outcome["links"] || []).map { |link| link.fetch("label") }
      }
    end
  end
end
