# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"

class RouteContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "schema", "state", "v1", "route", "route.schema.json")
  FIXTURES_PATH = File.join(ROOT, "schema", "state", "v1", "route", "fixtures")

  def test_schema_publishes_the_route_contract_metadata
    schema_document = read_json(SCHEMA_PATH)

    assert JSONSchemer.valid_schema?(schema_document)
    assert_equal 1, schema_document.fetch("x-contract-version")
    assert_equal "route", schema_document.fetch("x-record-family")
    assert_equal "#/$defs/lane_route_projection", schema_document.fetch("$ref")
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

  def test_route_value_accepts_both_interchangeable_forms
    schema = route_value_schema

    assert_empty schema.validate("gpt-5.6-sol/xhigh").to_a
    assert_empty schema.validate("model/effort").to_a
    assert_empty schema.validate({ "model" => "claude-opus-4-8", "effort" => "high" }).to_a
  end

  def test_route_value_rejects_malformed_forms
    schema = route_value_schema

    ["gpt-5.6-sol", "anthropic/claude/high", "/xhigh", "gpt/", " gpt/xhigh", ""].each do |value|
      refute_empty schema.validate(value).to_a, "expected compact string #{value.inspect} to be rejected"
    end
    [{ "model" => "m" }, { "effort" => "e" }, {}, { "model" => "m", "effort" => "e", "x" => 1 },
     { "model" => "", "effort" => "high" }, 42, nil, true].each do |value|
      refute_empty schema.validate(value).to_a, "expected #{value.inspect} to be rejected"
    end
  end

  def test_route_is_optional_but_never_null
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))

    assert_empty schema.validate({ "lane" => "x" }).to_a, "an omitted route is the only way to signal no route"
    refute_empty schema.validate({ "lane" => "x", "route" => nil }).to_a, "route must be omitted, never null"
  end

  def test_both_forms_canonicalize_to_the_same_model_and_effort
    compact = "gpt-5.6-sol/xhigh"
    structured = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }

    assert_equal structured, normalize_route(compact)
    assert_equal compact, route_chip(structured)
    assert_equal route_chip(compact), route_chip(structured)
    assert_equal structured, normalize_route(route_chip(structured))
  end

  def test_chip_rendering_replay_covers_both_forms_and_absent_degrade
    replay = read_fixture(File.join(FIXTURES_PATH, "replay", "route-chip-rendering.json"))
    schema = JSONSchemer.schema(read_json(SCHEMA_PATH))

    chips = replay.fetch("lanes").to_h do |lane|
      assert_empty schema.validate(lane).to_a, "replay lane #{lane['lane']} must conform"
      [lane.fetch("lane"), route_chip(lane["route"])]
    end

    assert_equal replay.dig("expected", "chips"), chips
  end

  private

  def route_value_schema
    JSONSchemer.schema(read_json(SCHEMA_PATH).merge("$ref" => "#/$defs/route"))
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

  def normalize_route(route)
    return route unless route.is_a?(String)

    model, effort = route.split("/", 2)
    { "model" => model, "effort" => effort }
  end

  # The dashboard chip: model/effort, or "hidden" when the lane has no route.
  def route_chip(route)
    return "hidden" if route.nil?

    normalized = normalize_route(route)
    "#{normalized.fetch('model')}/#{normalized.fetch('effort')}"
  end
end
