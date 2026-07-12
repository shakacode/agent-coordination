# frozen_string_literal: true

require "json"
require "minitest/autorun"

class StateContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCHEMA_PATH = File.join(ROOT, "contracts", "state-schema-v2.json")
  FIXTURE_PATH = File.join(ROOT, "contracts", "fixtures", "v2", "lane_closed.json")

  def test_lane_closed_fixture_conforms_to_published_v2_contract
    schema = JSON.parse(File.read(SCHEMA_PATH))
    fixture = JSON.parse(File.read(FIXTURE_PATH))
    event_schema = schema.fetch("$defs").fetch("lane_closed")

    assert_equal 2, schema.fetch("x-contract-version")
    assert_equal "default", schema.fetch("$defs").fetch("workspace").fetch("default")
    assert_empty event_schema.fetch("required") - fixture.keys
    assert_equal event_schema.fetch("properties").fetch("type").fetch("const"), fixture.fetch("type")
    assert_includes event_schema.fetch("properties").fetch("terminal").fetch("enum"), fixture.fetch("terminal")
    assert_equal "default", fixture.fetch("workspace")
    assert_equal %w[agent_id machine], fixture.fetch("closed_by").keys.sort
  end
end
