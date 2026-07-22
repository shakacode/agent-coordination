# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"

class UsageRecordContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "schema", "state", "v1", "usage", "usage-record.schema.json")
  FIXTURES_PATH = File.join(ROOT, "schema", "state", "v1", "usage", "fixtures")
  METRICS = %w[input_tokens output_tokens cost].freeze

  def test_schema_publishes_the_usage_record_contract_metadata
    schema_document = read_json(SCHEMA_PATH)

    assert JSONSchemer.valid_schema?(schema_document)
    assert_equal 1, schema_document.fetch("x-contract-version")
    assert_equal "usage", schema_document.fetch("x-record-family")
    assert_equal %w[workspace repo batch_id lane_name agent_id target model],
                 schema_document.fetch("x-logical-key")
    assert_equal "usage/{workspace}/{repo}/{batch_id}/{lane_name}/{agent_id}/{target}/{model}.json",
                 schema_document.dig("x-storage-key", "template")
    assert_equal "default", schema_document.dig("$defs", "workspace", "default")
    assert_equal %w[workspace repo batch_id lane_name agent_id target model],
                 schema_document.dig("$defs", "status_projection", "properties", "usage", "x-unique-key")
    assert_equal "producer",
                 schema_document.dig("$defs", "status_projection", "properties", "usage", "x-unique-key-enforcement")
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

  def test_optional_metric_discipline_accepts_null_and_em_dash_but_not_fabrications
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))
    known = read_fixture(File.join(FIXTURES_PATH, "valid", "usage-known.json"))

    %w[input_tokens output_tokens cost].each do |metric|
      assert_empty schema.validate(known.merge(metric => nil)).to_a, "expected null #{metric} to conform"
      assert_empty schema.validate(known.merge(metric => "—")).to_a, "expected em dash #{metric} to conform"
      refute_empty schema.validate(known.except(metric)).to_a, "expected omitted #{metric} to be rejected"
      refute_empty schema.validate(known.merge(metric => "0")).to_a, "expected fabricated string #{metric} rejected"
    end
    refute_empty schema.validate(known.merge("input_tokens" => -1)).to_a
    refute_empty schema.validate(known.merge("schema_version" => 2)).to_a
  end

  def test_status_projection_allows_omitted_or_empty_usage
    schema_document = read_json(SCHEMA_PATH)
    projection = JSONSchemer.schema(schema_document.merge("$ref" => "#/$defs/status_projection"))
    existing = { "claims" => [], "heartbeats" => [], "batches" => [], "events" => [] }

    assert_empty projection.validate(existing).to_a
    assert_empty projection.validate(existing.merge("usage" => [])).to_a
    refute_empty projection.validate(existing.merge("usage" => nil)).to_a
  end

  def test_by_model_aggregation_excludes_unknown_metrics
    schema_document = read_json(SCHEMA_PATH)
    projection = JSONSchemer.schema(schema_document.merge("$ref" => "#/$defs/status_projection"))
    replay = read_fixture(File.join(FIXTURES_PATH, "replay", "usage-by-model-aggregation.json"))
    records = replay.dig("status", "usage")

    assert_empty projection.validate(replay.fetch("status")).to_a
    actual = aggregate_usage(records)
    expected = replay.fetch("expected")

    assert_equal expected.fetch("records_with_unknown_metrics"), actual.fetch("records_with_unknown_metrics")
    assert_model_totals(expected.fetch("tokens_by_model"), actual.fetch("tokens_by_model"))
    assert_model_totals({ "batch" => expected.fetch("batch_totals") }, { "batch" => actual.fetch("batch_totals") })
  end

  def test_all_unknown_aggregate_preserves_unknown_instead_of_fabricating_zero
    schema_document = read_json(SCHEMA_PATH)
    projection = JSONSchemer.schema(schema_document.merge("$ref" => "#/$defs/status_projection"))
    replay = read_fixture(File.join(FIXTURES_PATH, "replay", "usage-all-unknown-batch.json"))
    records = replay.dig("status", "usage")

    assert_empty projection.validate(replay.fetch("status")).to_a
    actual = aggregate_usage(records)
    expected = replay.fetch("expected")

    assert_equal expected.fetch("records_with_unknown_metrics"), actual.fetch("records_with_unknown_metrics")
    assert_model_totals(expected.fetch("tokens_by_model"), actual.fetch("tokens_by_model"))
    %w[input_tokens output_tokens cost].each do |metric|
      assert_nil actual.fetch("batch_totals").fetch(metric), "batch #{metric} must stay unknown, not zero"
    end
  end

  def test_status_projection_procedurally_admits_duplicate_logical_keys
    schema_document = read_json(SCHEMA_PATH)
    projection = JSONSchemer.schema(schema_document.merge("$ref" => "#/$defs/status_projection"))
    fixture = read_fixture(File.join(FIXTURES_PATH, "procedural", "usage-duplicate-logical-key.json"))
    records = fixture.dig("status", "usage")

    assert_empty projection.validate(fixture.fetch("status")).to_a,
                 "JSON Schema validates the records but cannot enforce composite-key uniqueness"
    assert_equal 1, records.map { |record| logical_key(record) }.uniq.length
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

  def logical_key(record)
    %w[workspace repo batch_id lane_name agent_id target model].map { |field| record.fetch(field) }
  end

  def aggregate_usage(records)
    by_model = {}
    totals = new_accumulator
    unknown = 0
    records.each do |record|
      slot = (by_model[record.fetch("model")] ||= new_accumulator)
      unknown += 1 if accumulate(record, slot, totals)
    end
    {
      "tokens_by_model" => by_model.transform_values { |slot| finalize(slot) },
      "batch_totals" => finalize(totals),
      "records_with_unknown_metrics" => unknown
    }
  end

  def new_accumulator
    METRICS.to_h { |metric| [metric, { "sum" => 0, "seen" => false }] }
  end

  def accumulate(record, model_slot, totals)
    record_unknown = false
    METRICS.each do |metric|
      value = record.fetch(metric)
      if value.is_a?(Numeric)
        [model_slot, totals].each do |accumulator|
          accumulator[metric]["sum"] += value
          accumulator[metric]["seen"] = true
        end
      else
        record_unknown = true
      end
    end
    record_unknown
  end

  # A metric with no numeric contributor stays unknown (nil) rather than a fabricated zero.
  def finalize(accumulator)
    METRICS.to_h do |metric|
      entry = accumulator.fetch(metric)
      value = entry.fetch("seen") ? entry.fetch("sum") : nil
      value = value.round(2) if metric == "cost" && value
      [metric, value]
    end
  end

  def assert_model_totals(expected, actual)
    assert_equal expected.keys.sort, actual.keys.sort
    expected.each do |model, sums|
      %w[input_tokens output_tokens].each do |metric|
        assert_metric sums.fetch(metric), actual.fetch(model).fetch(metric), "#{model} #{metric}"
      end
      assert_metric sums.fetch("cost"), actual.fetch(model).fetch("cost"), "#{model} cost", delta: 0.001
    end
  end

  def assert_metric(expected, actual, message, delta: nil)
    if expected.nil?
      assert_nil actual, message
    elsif delta
      assert_in_delta expected, actual, delta, message
    else
      assert_equal expected, actual, message
    end
  end
end
