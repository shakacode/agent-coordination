# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "time"
require "tmpdir"

load File.expand_path("../bin/agent-coord", __dir__)

class AttentionCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "agent-coord")

  def setup
    @root = Dir.mktmpdir("agent-coord-attention")
    @config_home = Dir.mktmpdir("agent-coord-attention-config")
  end

  def teardown
    FileUtils.remove_entry(@root)
    FileUtils.remove_entry(@config_home)
  end

  def test_upsert_create_and_exact_read
    result = upsert(record)

    assert_success result
    path = File.join(@root, "attention", "default", "shakacode", "agent-coordination", "decision-1.json")
    assert File.file?(path)
    stored = JSON.parse(File.read(path))
    assert_equal "codex", stored.dig("source", "provider")
    assert_equal "unknown", stored.dig("source", "capabilities", "prompt_forwarding")

    get = run_cli("attention-get", "--workspace", "default", "--repo", "shakacode/agent-coordination",
                  "--attention-id", "decision-1", "--json")
    assert_success get
    assert_equal stored, JSON.parse(get.stdout).fetch("record")
  end

  def test_upsert_rejects_empty_and_invalid_utf8_record_input_cleanly
    ["", "{\"bad\":\"\xFF\"}".b].each do |contents|
      path = File.join(@root, "malformed-record.json")
      File.binwrite(path, contents)
      result = run_cli("attention-upsert", "--record-json", path, "--json")

      assert_equal 1, result.status.exitstatus
      assert_includes result.stderr, "attention record"
      refute_includes result.stderr, "bin/agent-coord:"
    end

    error = assert_raises(AgentCoord::Error) do
      AgentCoord::Runner.new([], stdin: StringIO.new).send(:load_attention_record, "-")
    end
    assert_includes error.message, "attention record"
  end

  def test_upsert_rejects_a_lower_source_generation_without_replacing_state
    assert_success upsert(record("source_generation" => 5, "question" => "Current question"))

    stale = upsert(record("source_generation" => 4, "question" => "Stale question"))

    assert_equal 2, stale.status.exitstatus
    assert_includes stale.stderr, "source generation 4 is older than stored generation 5"
    assert_equal "Current question", read_record.fetch("question")
  end

  def test_schema_valid_unicode_record_larger_than_64_kib_persists_within_worker_limit
    large = record("choices" => Array.new(10, "😀" * 2000))
    serialized = JSON.generate(large)
    assert_operator serialized.bytesize, :>, 64 * 1024
    assert_operator serialized.bytesize, :<=, 256 * 1024

    result = upsert(large)

    assert_success result
    assert_operator JSON.generate(read_record).bytesize, :<=, 256 * 1024
  end

  def test_upsert_rejects_a_refresh_older_than_the_preserved_timestamps
    assert_success upsert(record("source_generation" => 1,
                                 "created_at" => "2099-09-03T09:00:00Z",
                                 "refreshed_at" => "2099-09-03T09:20:00Z"))

    invalid_merge = upsert(record("source_generation" => 2,
                                  "created_at" => "2026-09-03T09:00:00Z",
                                  "refreshed_at" => "2026-09-03T09:20:00Z"))

    assert_equal 2, invalid_merge.status.exitstatus
    assert_includes invalid_merge.stderr, "attention refresh is older than the stored refresh"
    assert_equal 1, read_record.fetch("source_generation")
  end

  def test_higher_generation_upsert_rejects_an_older_refresh_timestamp
    assert_success upsert(record("source_generation" => 1, "refreshed_at" => "2026-09-03T10:00:00Z"))

    stale_refresh = upsert(record("source_generation" => 2, "refreshed_at" => "2026-09-03T09:30:00Z"))

    assert_equal 2, stale_refresh.status.exitstatus
    assert_includes stale_refresh.stderr, "attention refresh is older than the stored refresh"
    assert_equal 1, read_record.fetch("source_generation")
    assert_equal "2026-09-03T10:00:00Z", read_record.fetch("refreshed_at")
  end

  def test_refresh_preserves_created_at_and_resolved_record_requires_a_newer_generation_to_reopen
    assert_success upsert(record("source_generation" => 5, "created_at" => "2026-09-03T08:00:00Z"))
    assert_success upsert(record("source_generation" => 5, "created_at" => "2026-09-03T09:00:00Z",
                                 "question" => "Refreshed question"))
    assert_equal "2026-09-03T08:00:00Z", read_record.fetch("created_at")
    assert_equal "Refreshed question", read_record.fetch("question")

    assert_success resolve(6)
    refused = upsert(record("source_generation" => 6, "question" => "Same-generation reopen"))
    assert_equal 2, refused.status.exitstatus
    assert_includes refused.stderr, "must advance beyond resolved generation 6"

    assert_success upsert(record("source_generation" => 7, "question" => "Reopened question",
                                 "refreshed_at" => "2099-09-03T09:20:00Z"))
    reopened = read_record
    assert_equal "open", reopened.fetch("status")
    refute reopened.key?("resolved_at")
    assert_equal "2026-09-03T08:00:00Z", reopened.fetch("created_at")
  end

  def test_resolve_preserves_audit_identity_and_is_generation_fenced
    original = record("source_generation" => 5)
    assert_success upsert(original)

    stale = resolve(4)
    assert_equal 2, stale.status.exitstatus
    assert_includes stale.stderr, "source generation 4 is older than stored generation 5"

    assert_success resolve(6)
    resolved = read_record
    assert_equal "resolved", resolved.fetch("status")
    assert_equal 6, resolved.fetch("source_generation")
    assert_equal original.fetch("created_at"), resolved.fetch("created_at")
    assert_equal original.fetch("source"), resolved.fetch("source")
    assert resolved.fetch("resolved_at").end_with?("Z")
    assert_equal resolved.fetch("resolved_at"), resolved.fetch("refreshed_at")

    resolved_at = resolved.fetch("resolved_at")
    assert_success resolve(6)
    assert_equal resolved_at, read_record.fetch("resolved_at")
    assert_success resolve(7)
    assert_equal resolved_at, read_record.fetch("resolved_at")
    assert_equal 7, read_record.fetch("source_generation")
  end

  def test_resolve_keeps_timestamps_monotonic_when_stored_refresh_is_in_the_future
    future = "2099-09-03T09:20:00Z"
    assert_success upsert(record("created_at" => "2099-09-03T09:00:00Z", "refreshed_at" => future))

    assert_success resolve(2)
    resolved = read_record

    assert_operator Time.iso8601(resolved.fetch("refreshed_at")), :>=, Time.iso8601(future)
    assert_operator Time.iso8601(resolved.fetch("resolved_at")), :>=, Time.iso8601(future)
  end

  def test_resolve_preserves_fractional_precision_for_future_stored_timestamps
    created_at = "2099-01-01T00:00:00.100Z"
    refreshed_at = "2099-01-01T00:00:00.900Z"
    assert_success upsert(record("created_at" => created_at, "refreshed_at" => refreshed_at))

    assert_success resolve(2)
    resolved = read_record

    assert_equal Time.iso8601(refreshed_at), Time.iso8601(resolved.fetch("refreshed_at"))
    assert_equal Time.iso8601(refreshed_at), Time.iso8601(resolved.fetch("resolved_at"))
    assert_match(/[.]\d+Z\z/, resolved.fetch("refreshed_at"))
  end

  def test_resolve_preserves_more_than_nine_fractional_digits_from_the_latest_stored_timestamp
    created_at = "2099-01-01T00:00:00.00000000009Z"
    refreshed_at = "2099-01-01T00:00:00.00000000010Z"
    assert_success upsert(record("created_at" => created_at, "refreshed_at" => refreshed_at))

    assert_success resolve(2)
    resolved = read_record

    assert_equal refreshed_at, resolved.fetch("refreshed_at")
    assert_equal refreshed_at, resolved.fetch("resolved_at")
  end

  def test_resolved_record_rejects_resolved_at_before_created_at
    path = attention_file
    FileUtils.mkdir_p(File.dirname(path))
    resolved = record(
      "status" => "resolved",
      "resolved_at" => "2026-09-03T08:59:59Z"
    )
    File.write(path, JSON.generate(resolved))

    result = run_cli("attention-get", "--workspace", "default", "--repo", "shakacode/agent-coordination",
                     "--attention-id", "decision-1", "--json")

    assert_equal 2, result.status.exitstatus
    assert_includes result.stderr, "resolved_at must not precede created_at"
  end

  def test_list_is_open_only_bounded_and_deterministically_ranked
    assert_success upsert(record("id" => "architecture", "priority_class" => "product-architecture"))
    assert_success upsert(record("id" => "unblocks", "priority_class" => "unblocks-work"))
    assert_success upsert(record("id" => "urgent", "priority_class" => "urgent-risk"))
    assert_success resolve(2, id: "urgent")

    result = run_cli("attention-list", "--workspace", "default", "--repo", "shakacode/agent-coordination",
                     "--limit", "1", "--json")

    assert_success result
    payload = JSON.parse(result.stdout)
    assert_equal(["unblocks"], payload.fetch("records").map { |item| item.fetch("id") })
    assert_equal true, payload.fetch("truncated")
    assert_equal 1, payload.fetch("limit")

    included = run_cli("attention-list", "--workspace", "default", "--repo", "shakacode/agent-coordination",
                       "--include-resolved", "--json")
    assert_success included
    assert_equal(%w[urgent unblocks architecture],
                 JSON.parse(included.stdout).fetch("records").map { |item| item.fetch("id") })
  end

  def test_list_orders_rfc3339_timestamps_by_instant_not_source_text
    assert_success upsert(record("id" => "offset-earlier", "created_at" => "2026-09-03T10:00:00+02:00"))
    assert_success upsert(record("id" => "whole-second", "created_at" => "2026-09-03T09:00:00Z"))
    assert_success upsert(record("id" => "fractional-later", "created_at" => "2026-09-03T09:00:00.1Z"))

    result = run_cli("attention-list", "--workspace", "default", "--repo", "shakacode/agent-coordination", "--json")

    assert_success result
    ids = JSON.parse(result.stdout).fetch("records").map { |item| item.fetch("id") }
    assert_equal %w[offset-earlier whole-second fractional-later], ids
  end

  def test_list_refuses_a_filtered_http_result_instead_of_reporting_false_completeness
    store = Class.new do
      attr_reader :listed_prefix

      def list_json(prefix, maximum: nil)
        @listed_prefix = prefix
        @maximum = maximum
        []
      end

      def filtered_list?(prefix)
        prefix == @listed_prefix
      end

      def close; end
    end.new
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout:, stderr: StringIO.new)
    runner.define_singleton_method(:build_store) { |_options| store }

    error = assert_raises(AgentCoord::OperationalError) do
      runner.send(
        :attention_list,
        { workspace: "default", repo: "shakacode/agent-coordination", limit: 100, json: true }
      )
    end

    assert_equal "attention/default/shakacode/agent-coordination", store.listed_prefix
    assert_includes error.message, "attention list is filtered"
    assert_includes error.message, "incomplete"
    assert_empty stdout.string
  end

  def test_text_render_scrubs_id_and_question_without_changing_json
    hostile_id = "decision\nrow\e]0;owned\a\u0000"
    hostile_question = "choose\r\ncarefully\e]8;;https://example.invalid\a link\e]8;;\a\u0085"
    hostile = record("id" => hostile_id, "question" => hostile_question)
    text = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: text, stderr: StringIO.new)

    runner.send(:render_attention_text, hostile)

    rendered = text.string
    assert_equal 2, rendered.lines.length
    refute_match(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\u0080-\u009F]/, rendered)
    assert_includes rendered, "decision row]0;owned"
    assert_includes rendered, "choose carefully]8;;https://example.invalid link]8;;"

    json = StringIO.new
    AgentCoord::Runner.new([], stdout: json, stderr: StringIO.new)
                      .send(:emit_payload, { "record" => hostile }, { json: true }) { flunk "rendered text for JSON" }
    assert_equal hostile, JSON.parse(json.string).fetch("record")
  end

  def test_upsert_rejects_invalid_capability_truth
    invalid = record
    invalid.fetch("source").fetch("capabilities")["native_open"] = "untested"

    result = upsert(invalid)

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "native_open must be available, unavailable, or unknown"
  end

  def test_upsert_rejects_open_uri_with_a_malformed_port_without_a_backtrace
    payload = record
    payload["source"] = payload.fetch("source").merge("open_uri" => "https://example.test:not-a-port/thread")

    result = upsert(payload)

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "attention source open_uri must be an absolute URI"
    refute_includes result.stderr, "bin/agent-coord:"
  end

  def test_attention_timestamps_are_bounded
    over_bound = "2026-09-03T09:00:00.#{'1' * 50}Z"
    {
      "created_at" => -> { record("created_at" => over_bound) },
      "refreshed_at" => -> { record("refreshed_at" => over_bound) },
      "source last_seen_at" => lambda do
        payload = record
        payload["source"] = payload.fetch("source").merge("last_seen_at" => over_bound)
        payload
      end,
      "resolved_at" => -> { record("status" => "resolved", "resolved_at" => over_bound) }
    }.each do |field, payload|
      error = assert_raises(AgentCoord::Error) do
        AgentCoord::Runner.new([]).send(:validate_attention_record!, payload.call)
      end
      assert_includes error.message, "attention #{field} must be an RFC 3339 timestamp of at most 64 characters"
    end
  end

  def test_attention_writes_obey_the_split_brain_guard
    env_dir = File.join(@config_home, "agent-coord")
    FileUtils.mkdir_p(env_dir)
    env_file = File.join(env_dir, "http-env.sh")
    File.write(env_file, "AGENT_COORD_API_URL=https://fleet.example\n")

    blocked_upsert = implicit_cli("attention-upsert", "--record-json", write_record(record), "--json")
    blocked_resolve = implicit_cli(
      "attention-resolve", "--workspace", "default", "--repo", "shakacode/agent-coordination",
      "--attention-id", "decision-1", "--source-generation", "2", "--json"
    )

    [blocked_upsert, blocked_resolve].each do |result|
      assert_equal 2, result.status.exitstatus
      assert_includes result.stderr, "split-brain configuration"
      assert_includes result.stderr, env_file
    end
  end

  def test_attention_reads_prefer_the_status_state_root
    assert_success upsert(record)

    get = status_cli("attention-get", "--workspace", "default", "--repo", "shakacode/agent-coordination",
                     "--attention-id", "decision-1", "--json")
    list = status_cli("attention-list", "--workspace", "default", "--repo", "shakacode/agent-coordination",
                      "--json")

    assert_success get
    assert_equal "decision-1", JSON.parse(get.stdout).dig("record", "id")
    assert_success list
    listed_ids = JSON.parse(list.stdout).fetch("records").map { |item| item.fetch("id") }
    assert_equal ["decision-1"], listed_ids
  end

  def test_attention_key_components_are_bounded_to_keep_paths_under_worker_limit
    repository = "#{'o' * 79}/#{'r' * 80}"
    boundary = record("workspace" => "w" * 160, "repository" => repository, "id" => "i" * 160)

    assert_success upsert(boundary)
    path = File.join("attention", boundary.fetch("workspace"), repository, "#{boundary.fetch('id')}.json")
    assert_equal 497, path.bytesize

    {
      "workspace" => "w" * 161,
      "repository" => "#{'o' * 80}/#{'r' * 80}",
      "id" => "i" * 161
    }.each do |field, value|
      result = upsert(record(field => value))
      assert_equal 1, result.status.exitstatus, "#{field} should be rejected"
      assert_includes result.stderr, "attention #{field} must be at most 160 characters"
    end
  end

  def test_attention_identity_key_components_must_be_strings
    %w[workspace id repository].product([123, true]).each do |field, value|
      result = upsert(record(field => value))

      assert_equal 1, result.status.exitstatus, "#{field}=#{value.inspect} should be rejected"
      assert_includes result.stderr, "attention #{field} must be a string"
      refute_includes result.stderr, "bin/agent-coord:"
    end
  end

  def test_attention_generation_is_bounded_to_json_safe_integers_for_upsert_and_resolve
    maximum = 9_007_199_254_740_991
    assert_success upsert(record("source_generation" => maximum))

    oversized_upsert = upsert(record("source_generation" => maximum + 1))
    assert_equal 1, oversized_upsert.status.exitstatus
    assert_includes oversized_upsert.stderr, "between 0 and #{maximum}"

    oversized_resolve = resolve(maximum + 1)
    assert_equal 1, oversized_resolve.status.exitstatus
    assert_includes oversized_resolve.stderr, "between 0 and #{maximum}"
    assert_equal maximum, read_record.fetch("source_generation")
  end

  def test_integral_json_numeric_generation_is_normalized_before_persistence_and_output
    assert_success upsert(record("source_generation" => 1))
    result = upsert(record("source_generation" => 2.0))

    assert_success result
    emitted = JSON.parse(result.stdout).dig("record", "source_generation")
    persisted = read_record.fetch("source_generation")
    assert_instance_of Integer, emitted
    assert_instance_of Integer, persisted
    assert_equal 2, emitted
    assert_equal 2, persisted
  end

  def test_attention_generation_rejects_fractional_nonfinite_and_rounded_unsafe_numbers
    fractional = upsert(record("source_generation" => 1.5))
    assert_equal 1, fractional.status.exitstatus
    assert_includes fractional.stderr, "must be an integer between"

    runner = AgentCoord::Runner.new([])
    [Float::NAN, Float::INFINITY, -Float::INFINITY, 9_007_199_254_740_993.0].each do |generation|
      error = assert_raises(AgentCoord::Error) do
        runner.send(:validate_attention_record!, record("source_generation" => generation))
      end
      assert_includes error.message, "must be an integer between"
    end
  end

  def test_attention_lifecycle_rejects_stored_identity_that_does_not_match_its_path
    path = attention_file
    FileUtils.mkdir_p(File.dirname(path))

    attention_lifecycle_commands.each do |command|
      File.write(path, JSON.generate(record("id" => "different-id")))
      result = command.call

      assert_equal 2, result.status.exitstatus
      assert_includes result.stderr, "stored attention identity does not match path"
      assert_includes result.stderr, "attention/default/shakacode/agent-coordination/decision-1.json"
      refute_includes result.stderr, "bin/agent-coord:"
    end
  end

  def test_attention_lifecycle_reports_malformed_stored_json_as_path_scoped_operational_error
    path = attention_file
    FileUtils.mkdir_p(File.dirname(path))

    ["{not-json", "{\"bad\":\"\xFF\"}".b].each do |payload|
      attention_lifecycle_commands.each do |command|
        File.binwrite(path, payload)
        result = command.call

        assert_equal 2, result.status.exitstatus
        assert_includes result.stderr, "malformed stored JSON"
        assert_includes result.stderr, "attention/default/shakacode/agent-coordination/decision-1.json"
        refute_includes result.stderr, "bin/agent-coord:"
      end
    end
  end

  def test_attention_list_requests_the_hard_scan_cap
    store = Class.new do
      attr_reader :maximum

      def list_json(_prefix, maximum: nil)
        @maximum = maximum
        []
      end

      def filtered_list?(_prefix) = false
      def close; end
    end.new
    runner = AgentCoord::Runner.new([], stdout: StringIO.new, stderr: StringIO.new)
    runner.define_singleton_method(:build_store) { |_options| store }

    runner.send(:attention_list, { workspace: "default", repo: "shakacode/agent-coordination", json: true })

    assert_equal 1000, store.maximum
  end

  def test_local_attention_scan_fails_before_parsing_more_than_the_hard_cap
    directory = File.dirname(attention_file)
    FileUtils.mkdir_p(directory)
    1001.times { |index| File.write(File.join(directory, format("%04d.json", index)), "{not-json") }

    error = assert_raises(AgentCoord::OperationalError) do
      AgentCoord::LocalStore.new(@root).list_json(
        "attention/default/shakacode/agent-coordination", maximum: 1000
      )
    end

    assert_includes error.message, "exceeds scan maximum 1000"
    refute_includes error.message, "malformed stored JSON"
  end

  def test_attention_repository_storage_grammar_rejects_dot_aliases_and_persists_dot_prefixed_names
    ["foo..bar/repo", "owner/foo..bar", "./foo", "repo/."].each do |repository|
      result = upsert(record("repository" => repository))

      assert_equal 1, result.status.exitstatus, "#{repository.inspect} should be rejected"
      assert_includes result.stderr, "invalid attention repo"
    end
    assert_empty Dir[File.join(@root, "attention", "**", "*.json")]

    [".github/foo", "shakacode/.github"].each do |repository|
      result = upsert(record("repository" => repository))

      assert_success result
      assert File.file?(File.join(@root, "attention", "default", repository, "decision-1.json"))
    end
  end

  def test_attention_timestamps_require_an_explicit_rfc3339_offset_in_every_timezone
    offsetless = "2026-09-03T09:00:00"
    timestamp_payloads = {
      "created_at" => -> { record("created_at" => offsetless) },
      "refreshed_at" => -> { record("refreshed_at" => offsetless) },
      "source last_seen_at" => lambda do
        payload = record
        payload["source"] = payload.fetch("source").merge("last_seen_at" => offsetless)
        payload
      end
    }

    %w[UTC Pacific/Honolulu].each do |timezone|
      timestamp_payloads.each do |field, payload|
        result = upsert(payload.call, env: { "TZ" => timezone })

        assert_equal 1, result.status.exitstatus, "#{field} should be rejected under #{timezone}"
        assert_includes result.stderr, "attention #{field} must be an RFC 3339 timestamp"
      end
    end
  end

  def test_attention_timestamps_accept_offsets_fractions_and_lowercase_t_and_z
    payload = record(
      "created_at" => "2026-09-03t09:00:00.125z",
      "refreshed_at" => "2026-09-03T11:00:00.5+02:00"
    )
    payload["source"] = payload.fetch("source").merge("last_seen_at" => "2026-09-03t09:20:00.25z")

    assert_success upsert(payload)
  end

  private

  def attention_lifecycle_commands
    [
      lambda do
        run_cli("attention-get", "--workspace", "default", "--repo", "shakacode/agent-coordination",
                "--attention-id", "decision-1", "--json")
      end,
      -> { resolve(2) },
      -> { upsert(record("source_generation" => 2)) },
      -> { run_cli("attention-list", "--workspace", "default", "--repo", "shakacode/agent-coordination", "--json") }
    ]
  end

  def record(overrides = {})
    {
      "schema_version" => 1,
      "workspace" => "default",
      "id" => "decision-1",
      "repository" => "shakacode/agent-coordination",
      "target" => "https://github.com/shakacode/agent-coordination/issues/292",
      "status" => "open",
      "kind" => "architecture",
      "question" => "Which bounded path should resume?",
      "choices" => ["Continue the bounded slice", "Stop and redesign"],
      "priority_class" => "current-head-merge",
      "priority_reason" => "Unblocks exact-head work",
      "safe_resume" => "Resume only the bounded record family",
      "source" => {
        "provider" => "codex",
        "host_id" => "m1",
        "task_id" => "task-1",
        "open_uri" => "codex://threads/task-1",
        "last_seen_at" => "2026-09-03T09:20:00Z",
        "capabilities" => { "native_open" => "available", "prompt_forwarding" => "unknown" }
      },
      "source_generation" => 1,
      "created_at" => "2026-09-03T09:00:00Z",
      "refreshed_at" => "2026-09-03T09:20:00Z"
    }.merge(overrides)
  end

  def upsert(payload, env: {})
    run_cli("attention-upsert", "--record-json", write_record(payload), "--json", env:)
  end

  def write_record(payload)
    file = File.join(@root, "record.json")
    File.write(file, JSON.generate(payload))
    file
  end

  def resolve(generation, id: "decision-1")
    run_cli("attention-resolve", "--workspace", "default", "--repo", "shakacode/agent-coordination",
            "--attention-id", id, "--source-generation", generation.to_s, "--json")
  end

  def read_record(id = "decision-1")
    path = attention_file(id)
    JSON.parse(File.read(path))
  end

  def attention_file(id = "decision-1")
    File.join(@root, "attention", "default", "shakacode", "agent-coordination", "#{id}.json")
  end

  def run_cli(*args, env: {})
    Open3.capture3(
      { "XDG_CONFIG_HOME" => @config_home }.merge(env),
      "ruby", BIN, *args, "--ignore-user-config", "--state-root", @root
    ).then { |stdout, stderr, status| Struct.new(:stdout, :stderr, :status).new(stdout, stderr, status) }
  end

  def implicit_cli(*args)
    Open3.capture3(
      {
        "XDG_CONFIG_HOME" => @config_home,
        "XDG_STATE_HOME" => @root,
        "AGENT_COORD_API_URL" => nil,
        "AGENT_COORD_API_TOKEN" => nil,
        "AGENT_COORD_STATE_ROOT" => nil,
        "AGENT_COORD_STATUS_STATE_ROOT" => nil,
        "AGENT_COORD_LOCAL" => nil
      },
      "ruby", BIN, *args
    ).then { |stdout, stderr, status| Struct.new(:stdout, :stderr, :status).new(stdout, stderr, status) }
  end

  def status_cli(*args)
    Open3.capture3(
      {
        "XDG_CONFIG_HOME" => @config_home,
        "XDG_STATE_HOME" => File.join(@root, "unused-state-home"),
        "AGENT_COORD_API_URL" => nil,
        "AGENT_COORD_API_TOKEN" => nil,
        "AGENT_COORD_STATE_ROOT" => nil,
        "AGENT_COORD_STATUS_STATE_ROOT" => @root
      },
      "ruby", BIN, *args
    ).then { |stdout, stderr, status| Struct.new(:stdout, :stderr, :status).new(stdout, stderr, status) }
  end

  def assert_success(result)
    assert_equal 0, result.status.exitstatus, result.stderr
  end
end
