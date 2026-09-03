# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

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

  def test_upsert_rejects_a_lower_source_generation_without_replacing_state
    assert_success upsert(record("source_generation" => 5, "question" => "Current question"))

    stale = upsert(record("source_generation" => 4, "question" => "Stale question"))

    assert_equal 2, stale.status.exitstatus
    assert_includes stale.stderr, "source generation 4 is older than stored generation 5"
    assert_equal "Current question", read_record.fetch("question")
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

    assert_success upsert(record("source_generation" => 7, "question" => "Reopened question"))
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

  def test_upsert_rejects_invalid_capability_truth
    invalid = record
    invalid.fetch("source").fetch("capabilities")["native_open"] = "untested"

    result = upsert(invalid)

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "native_open must be available, unavailable, or unknown"
  end

  private

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

  def upsert(payload)
    file = File.join(@root, "record.json")
    File.write(file, JSON.generate(payload))
    run_cli("attention-upsert", "--record-json", file, "--json")
  end

  def resolve(generation, id: "decision-1")
    run_cli("attention-resolve", "--workspace", "default", "--repo", "shakacode/agent-coordination",
            "--attention-id", id, "--source-generation", generation.to_s, "--json")
  end

  def read_record(id = "decision-1")
    path = File.join(@root, "attention", "default", "shakacode", "agent-coordination", "#{id}.json")
    JSON.parse(File.read(path))
  end

  def run_cli(*args)
    Open3.capture3(
      { "XDG_CONFIG_HOME" => @config_home },
      "ruby", BIN, *args, "--ignore-user-config", "--state-root", @root
    ).then { |stdout, stderr, status| Struct.new(:stdout, :stderr, :status).new(stdout, stderr, status) }
  end

  def assert_success(result)
    assert_equal 0, result.status.exitstatus, result.stderr
  end
end
