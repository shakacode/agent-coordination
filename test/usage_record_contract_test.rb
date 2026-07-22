# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"

class UsageRecordContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "schema", "state", "v1", "usage", "usage-record.schema.json")
  FIXTURES_PATH = File.join(ROOT, "schema", "state", "v1", "usage", "fixtures")

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
    by_model = Hash.new { |hash, key| hash[key] = zeroed_totals }
    totals = zeroed_totals
    unknown = 0
    records.each do |record|
      record_unknown = accumulate(record, by_model[record.fetch("model")], totals)
      unknown += 1 if record_unknown
    end
    { "tokens_by_model" => by_model, "batch_totals" => totals, "records_with_unknown_metrics" => unknown }
  end

  def accumulate(record, model_slot, totals)
    record_unknown = false
    %w[input_tokens output_tokens cost].each do |field|
      value = record.fetch(field)
      if value.is_a?(Numeric)
        model_slot[field] += value
        totals[field] += value
      else
        record_unknown = true
      end
    end
    record_unknown
  end

  def zeroed_totals
    { "input_tokens" => 0, "output_tokens" => 0, "cost" => 0.0 }
  end

  def assert_model_totals(expected, actual)
    assert_equal expected.keys.sort, actual.keys.sort
    expected.each do |model, sums|
      assert_equal sums.fetch("input_tokens"), actual.fetch(model).fetch("input_tokens"), "#{model} input_tokens"
      assert_equal sums.fetch("output_tokens"), actual.fetch(model).fetch("output_tokens"), "#{model} output_tokens"
      assert_in_delta sums.fetch("cost"), actual.fetch(model).fetch("cost"), 0.001, "#{model} cost"
    end
  end
end
