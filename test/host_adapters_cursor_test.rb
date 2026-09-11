# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/agent_coordination/host_adapters"

class HostAdaptersCursorTest < Minitest::Test
  def test_parses_cursor_jsonl_role_message_records
    records = [
      {
        "role" => "user",
        "message" => { "content" => [{ "type" => "text", "text" => "plan a PR" }] }
      },
      {
        "role" => "assistant",
        "model" => "grok-4.6",
        "message" => {
          "content" => [{ "type" => "text", "text" => "reading the skill" }],
          "usage" => { "input_tokens" => 12, "output_tokens" => 4, "total_tokens" => 16 }
        }
      }
    ]
    parsed = AgentCoord::Telemetry::HostAdapters::Parser.new("cursor").parse(
      records.map { |record| JSON.generate(record) }.join("\n"),
      "cursor:4915a1d9-fixture"
    )

    assert_empty parsed.fetch("errors")
    assert_equal 1, parsed.fetch("sessions").length
    session = parsed.fetch("sessions").fetch(0)
    assert_equal "cursor", session.fetch("host_family")
    assert_equal "grok-4.6", session.fetch("model")
    assert_equal 1, session.fetch("usage").length
    assert_equal 12, session.fetch("usage").fetch(0).fetch("input_tokens")
  end

  def test_unknown_host_family_is_recorded_not_parsed_as_claude
    parsed = AgentCoord::Telemetry::HostAdapters::Parser.new("unknown").parse(
      JSON.generate("role" => "assistant", "message" => {}),
      "unknown:fixture"
    )

    assert_equal [{ "record_ordinal" => 1, "reason" => "unsupported_host_family" }], parsed.fetch("errors")
    assert_empty parsed.fetch("sessions")
  end
end
