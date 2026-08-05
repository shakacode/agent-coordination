# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../lib/agent_coordination/ledger"
require_relative "../lib/agent_coordination/pricing"
require_relative "../lib/agent_coordination/harvester"

class TelemetryHarvesterTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  ROOT = File.expand_path("..", __dir__)
  CLI = File.join(ROOT, "bin", "agent-coord-harvest")
  FIXTURES = File.join(ROOT, "test", "fixtures", "telemetry")

  def test_named_batch_harvest_initializes_queryable_sqlite_ledger
    Dir.mktmpdir("agent-coordination-ledger") do |dir|
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      File.write(source_path, JSON.generate(coordination_fixture))

      stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )

      assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
      assert_equal "harvested batches=1 targets=1 usage=0\n", stdout
      assert_empty stderr
      assert File.file?(ledger_path), "harvest did not create the SQLite ledger"

      table_names = sqlite_query(ledger_path, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
      assert_includes table_names, "schema_migrations"
      assert_includes table_names, "batches"
      assert_includes table_names, "target_units"

      batches = sqlite_query(ledger_path, "SELECT batch_id, repo, source_kind FROM batches")
      assert_equal ["batch-fixture|shakacode/agent-coordination|coordination"], batches
    end
  end

  def test_date_range_harvest_is_inclusive_and_idempotent # rubocop:disable Metrics/MethodLength
    Dir.mktmpdir("agent-coordination-ledger-range") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      source = coordination_fixture
      source["claims"] << {
        "batch_id" => "batch-fixture", "repo" => "shakacode/agent-coordination",
        "target" => "78", "status" => "released", "terminal" => "done"
      }
      source["events"] << {
        "id" => "event-range-fixture", "batch_id" => "batch-fixture",
        "repo" => "shakacode/agent-coordination", "target" => "78",
        "type" => "lane_closed", "at" => "2026-07-18T01:30:00Z"
      }
      base_batch = coordination_fixture.fetch("batches").first
      {
        "batch-before" => "2026-07-17T23:59:59Z",
        "batch-start" => "2026-07-18T00:00:00Z",
        "batch-end" => "2026-07-18T23:59:59Z",
        "batch-after" => "2026-07-19T00:00:00Z"
      }.each do |batch_id, registered_at|
        source.fetch("batches") << base_batch.merge(
          "batch_id" => batch_id, "registered_at" => registered_at, "updated_at" => registered_at
        )
      end
      File.write(source_path, JSON.generate(source))

      2.times do
        stdout, stderr, status = Open3.capture3(
          CLI, "harvest", "--ledger", ledger_path,
          "--coordination-json", source_path,
          "--from", "2026-07-18", "--to", "2026-07-18"
        )
        assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
        assert_equal "harvested batches=3 targets=3 usage=0\n", stdout
        assert_empty stderr
      end

      assert_equal %w[batch-end batch-fixture batch-start], sqlite_query(
        ledger_path, "SELECT batch_id FROM batches ORDER BY batch_id"
      )
      assert_equal ["3"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM target_units")
      assert_equal ["1"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM claims")
      assert_equal ["1"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM events")

      source.fetch("batches").reject! do |batch|
        %w[batch-end batch-fixture batch-start].include?(batch.fetch("batch_id"))
      end
      File.write(source_path, JSON.generate(source))
      stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path,
        "--from", "20260718", "--to", "20260718"
      )
      assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
      assert_equal "harvested batches=0 targets=0 usage=0\n", stdout
      assert_empty stderr
      assert_empty sqlite_query(ledger_path, "SELECT batch_id FROM batches")
      assert_empty sqlite_query(ledger_path, "SELECT target FROM target_units")
      assert_empty sqlite_query(ledger_path, "SELECT batch_id FROM claims")
      assert_empty sqlite_query(ledger_path, "SELECT batch_id FROM events")
    end
  end

  def test_coordination_refresh_without_github_input_preserves_pr_links_and_review_attribution
    Dir.mktmpdir("agent-coordination-ledger-optional-github-refresh") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      github_path = File.join(dir, "github.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      FileUtils.cp(File.join(FIXTURES, "coordination.json"), source_path)
      github = JSON.parse(File.read(File.join(FIXTURES, "github.json")))
      github.fetch("pull_requests").first["reviews"] = [{ "id" => "review-retained", "findings" => [] }]
      File.write(github_path, JSON.pretty_generate(github))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr
      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr

      assert_equal ["78|merged|1", "79|open-pr|0"], sqlite_query(
        ledger_path,
        "SELECT target_units.target, target_units.outcome, COUNT(review_receipts.id) " \
        "FROM target_units " \
        "JOIN target_pr_links ON target_pr_links.target_unit_id = target_units.id " \
        "LEFT JOIN review_receipts ON review_receipts.target_unit_id = target_units.id " \
        "GROUP BY target_units.id ORDER BY target_units.target"
      )
    end
  end

  def test_partial_refresh_preserves_ambiguous_shared_pr_review_attribution
    Dir.mktmpdir("agent-coordination-ledger-shared-pr-refresh") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      github_path = File.join(dir, "github.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      source = coordination_fixture
      shared_url = "https://github.com/shakacode/agent-coordination/pull/178"
      source.fetch("batches").first.fetch("lanes").first["pr_url"] = shared_url
      second = Marshal.load(Marshal.dump(source.fetch("batches").first))
      second["batch_id"] = "batch-second"
      second.fetch("lanes").first["targets"] = ["79"]
      source.fetch("batches") << second
      File.write(source_path, JSON.pretty_generate(source))
      github_document = {
        "pull_requests" => [{
          "batch_id" => "batch-fixture", "repo" => "shakacode/agent-coordination", "target" => "78",
          "number" => 178, "url" => shared_url, "state" => "open",
          "reviews" => [{ "id" => "shared-review", "findings" => [] }]
        }]
      }
      File.write(github_path, JSON.pretty_generate(github_document))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--from", "2026-07-18", "--to", "2026-07-18"
      )
      assert status.success?, stderr
      assert_equal ["2|1"], sqlite_query(
        ledger_path,
        "SELECT COUNT(*), review_receipts.target_unit_id IS NULL FROM target_pr_links, review_receipts"
      )

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr
      assert_equal ["2|1"], sqlite_query(
        ledger_path,
        "SELECT COUNT(*), review_receipts.target_unit_id IS NULL FROM target_pr_links, review_receipts"
      )
    end
  end

  def test_refresh_replaces_claims_and_events_and_terminal_state_outranks_merged_pr
    Dir.mktmpdir("agent-coordination-ledger-coordination-refresh") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      github_path = File.join(dir, "github.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      coordination = JSON.parse(File.read(File.join(FIXTURES, "coordination.json")))
      coordination.fetch("batches").first.fetch("lanes") << {
        "name" => "event-terminal", "targets" => ["80"], "status" => "done"
      }
      coordination.fetch("events") << {
        "id" => "event-terminal-failed", "batch_id" => "batch-fixture",
        "repo" => "shakacode/agent-coordination", "target" => "80",
        "type" => "lane_closed", "terminal" => "failed", "at" => "2026-07-18T02:00:00Z"
      }
      File.write(source_path, JSON.pretty_generate(coordination))
      github = JSON.parse(File.read(File.join(FIXTURES, "github.json")))
      github.fetch("pull_requests") << {
        "batch_id" => "batch-fixture", "repo" => "shakacode/agent-coordination", "target" => "80",
        "number" => 180, "url" => "https://github.com/shakacode/agent-coordination/pull/180", "state" => "merged"
      }
      File.write(github_path, JSON.pretty_generate(github))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr
      coordination.fetch("claims").first["terminal"] = "failed"
      File.write(source_path, JSON.pretty_generate(coordination))
      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr

      assert_equal ["1|2"], sqlite_query(
        ledger_path, "SELECT (SELECT COUNT(*) FROM claims), (SELECT COUNT(*) FROM events)"
      )
      assert_equal ["78|failed", "80|failed"], sqlite_query(
        ledger_path, "SELECT target, outcome FROM target_units WHERE target IN ('78', '80') ORDER BY target"
      )
    end
  end

  def test_coordination_and_github_inputs_converge_to_normalized_target_outcomes
    Dir.mktmpdir("agent-coordination-ledger-normalized") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      github_path = File.join(dir, "github.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      FileUtils.cp(File.join(FIXTURES, "coordination.json"), source_path)
      FileUtils.cp(File.join(FIXTURES, "github.json"), github_path)

      stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
      assert_empty stderr

      assert_equal ["78|merged|exact", "79|open-pr|exact"], sqlite_query(
        ledger_path, "SELECT target, outcome, join_status FROM target_units ORDER BY target"
      )
      assert_equal ["78|checker", "78|maker", "79|open-lane"], sqlite_query(
        ledger_path,
        "SELECT target_units.target, lane_memberships.lane_id " \
        "FROM lane_memberships JOIN target_units ON target_units.id = lane_memberships.target_unit_id " \
        "ORDER BY target_units.target, lane_memberships.lane_id"
      )
      assert_equal ["missing_target|"], sqlite_query(
        ledger_path, "SELECT join_status, target FROM target_observations WHERE join_status != 'exact'"
      )
      refute(sqlite_query(ledger_path, "SELECT source_ref FROM source_artifacts").any? { |ref| ref.include?(dir) })

      coordination = JSON.parse(File.read(source_path))
      coordination.fetch("batches").first.fetch("lanes").reject! { |lane| lane.fetch("targets", []).include?("79") }
      File.write(source_path, JSON.pretty_generate(coordination))
      github = JSON.parse(File.read(github_path))
      github.fetch("pull_requests").reject! { |pull_request| pull_request.fetch("target") == "79" }
      File.write(github_path, JSON.pretty_generate(github))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr
      assert_equal ["78"], sqlite_query(ledger_path, "SELECT target FROM target_units ORDER BY target")
      assert_equal ["178"], sqlite_query(ledger_path, "SELECT number FROM github_prs ORDER BY number")
    end
  end

  def test_named_batch_harvest_recomputes_outcomes_for_all_refreshed_github_rows # rubocop:disable Metrics/MethodLength
    Dir.mktmpdir("agent-coordination-ledger-github-refresh") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      github_path = File.join(dir, "github.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      coordination = JSON.parse(File.read(File.join(FIXTURES, "coordination.json")))
      coordination.fetch("batches") << {
        "batch_id" => "batch-second",
        "repo" => "shakacode/agent-coordination",
        "status" => "completed",
        "registered_at" => "2026-07-18T03:00:00Z",
        "updated_at" => "2026-07-18T04:00:00Z",
        "lanes" => [{
          "name" => "second-maker", "targets" => ["80"], "status" => "done",
          "pr_url" => "https://github.com/shakacode/agent-coordination/pull/180"
        }]
      }
      File.write(source_path, JSON.pretty_generate(coordination))
      github = JSON.parse(File.read(File.join(FIXTURES, "github.json")))
      github.fetch("pull_requests") << {
        "batch_id" => "batch-second",
        "repo" => "shakacode/agent-coordination",
        "target" => "80",
        "number" => 180,
        "url" => "https://github.com/shakacode/agent-coordination/pull/180",
        "state" => "open"
      }
      File.write(github_path, JSON.pretty_generate(github))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--from", "2026-07-18", "--to", "2026-07-18"
      )
      assert status.success?, stderr
      assert_equal ["open|open-pr"], sqlite_query(
        ledger_path,
        "SELECT github_prs.state, target_units.outcome FROM target_units " \
        "JOIN target_pr_links ON target_pr_links.target_unit_id = target_units.id " \
        "JOIN github_prs ON github_prs.id = target_pr_links.github_pr_id " \
        "WHERE target_units.batch_id = 'batch-second'"
      )

      github.fetch("pull_requests").last["state"] = "merged"
      File.write(github_path, JSON.pretty_generate(github))
      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr
      assert_equal ["merged|merged"], sqlite_query(
        ledger_path,
        "SELECT github_prs.state, target_units.outcome FROM target_units " \
        "JOIN target_pr_links ON target_pr_links.target_unit_id = target_units.id " \
        "JOIN github_prs ON github_prs.id = target_pr_links.github_pr_id " \
        "WHERE target_units.batch_id = 'batch-second'"
      )
    end
  end

  def test_host_adapters_store_only_incremental_aggregate_metadata_and_exact_links # rubocop:disable Metrics/MethodLength
    Dir.mktmpdir("agent-coordination-ledger-hosts") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      codex_root = File.join(dir, "credential-bearing-codex-root")
      claude_root = File.join(dir, "credential-bearing-claude-root")
      FileUtils.cp(File.join(FIXTURES, "coordination.json"), source_path)
      FileUtils.cp_r(File.join(FIXTURES, "codex"), codex_root)
      FileUtils.cp_r(File.join(FIXTURES, "claude"), claude_root)

      secret = "SYNTHETIC_TRANSCRIPT_SECRET_78"
      codex_log = Dir.glob(File.join(codex_root, "sessions", "**", "linked.jsonl")).fetch(0)
      File.open(codex_log, "a") do |file|
        file.puts JSON.generate("type" => "response_item", "payload" => { "content" => secret })
        file.puts %({"type":"broken","content":"#{secret}")
      end
      claude_log = Dir.glob(File.join(claude_root, "projects", "**", "linked.jsonl")).fetch(0)
      File.open(claude_log, "a") do |file|
        file.puts JSON.generate(
          "type" => "assistant",
          "sessionId" => "claude-fixture-session",
          "pricing_profile" => "standard",
          "message" => {
            "model" => secret,
            "effort" => secret,
            "usage" => {
              "input_tokens" => 0,
              "cache_read_input_tokens" => 0,
              "cache_creation_input_tokens" => 0,
              "output_tokens" => 0,
              "total_tokens" => 0
            }
          }
        )
      end

      2.times do
        stdout, stderr, status = Open3.capture3(
          CLI, "harvest", "--ledger", ledger_path,
          "--coordination-json", source_path,
          "--codex-root", codex_root, "--claude-root", claude_root,
          "--batch-id", "batch-fixture"
        )
        assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
        assert_equal "harvested batches=1 targets=2 usage=5\n", stdout
        assert_empty stderr
        refute_includes stdout, secret
        refute_includes stderr, secret
      end

      assert_equal ["3"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM host_sessions")
      assert_equal ["5"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM usage_calls")
      assert_equal ["2"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM session_lane_links")
      assert_equal ["1"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM ingestion_errors")
      assert_equal ["unmatched|1|1"], sqlite_query(
        ledger_path,
        "SELECT host_sessions.link_status, usage_calls.input_tokens IS NULL, usage_calls.total_tokens IS NULL " \
        "FROM host_sessions JOIN usage_calls ON usage_calls.host_session_id = host_sessions.id " \
        "WHERE host_sessions.link_status = 'unmatched'"
      )
      assert_equal ["claude|2|500|300|200|100||1100", "codex|3|1100|220|110|65|11|1496"], sqlite_query(
        ledger_path,
        "SELECT host_sessions.host_family, COUNT(*), SUM(usage_calls.input_tokens), " \
        "SUM(usage_calls.cache_read_tokens), SUM(usage_calls.cache_write_tokens), " \
        "SUM(usage_calls.output_tokens), SUM(usage_calls.reasoning_output_tokens), " \
        "SUM(usage_calls.total_tokens) FROM usage_calls " \
        "JOIN host_sessions ON host_sessions.id = usage_calls.host_session_id " \
        "GROUP BY host_sessions.host_family ORDER BY host_sessions.host_family"
      )
      assert_equal ["ac-d-78-harvester|64", "unlinked|64"], sqlite_query(
        ledger_path,
        "SELECT cwd_basename, LENGTH(cwd_sha256) FROM host_sessions ORDER BY cwd_basename"
      ).uniq

      database_bytes = File.binread(ledger_path)
      refute_includes database_bytes, secret
      refute_includes database_bytes, codex_root
      refute_includes database_bytes, claude_root
    end
  end

  def test_pricing_cost_allocation_and_review_economics_are_integer_and_unknown_safe # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Dir.mktmpdir("agent-coordination-ledger-costs") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      github_path = File.join(dir, "github.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      codex_root = File.join(dir, "codex")
      claude_root = File.join(dir, "claude")
      FileUtils.cp(File.join(FIXTURES, "coordination.json"), source_path)
      FileUtils.cp_r(File.join(FIXTURES, "codex"), codex_root)
      FileUtils.cp_r(File.join(FIXTURES, "claude"), claude_root)

      finding_secret = "SYNTHETIC_REVIEW_BODY_SECRET_78"
      github = JSON.parse(File.read(File.join(FIXTURES, "github.json")))
      github.fetch("pull_requests").first["reviews"] = [
        {
          "id" => "review-fixture-priced",
          "provenance" => {
            "model" => "gpt-5.6-terra",
            "effort" => "high",
            "pricing_profile" => "standard",
            "usage" => {
              "input_tokens" => 1000,
              "output_tokens" => 100,
              "cache_read_tokens" => 200,
              "cache_write_tokens" => 0,
              "reasoning_output_tokens" => 0,
              "total_tokens" => 1300
            }
          },
          "findings" => [
            {
              "id" => "finding-fixture-1",
              "severity" => "P1",
              "disposition" => "should_fix",
              "verification_status" => "verified",
              "title" => finding_secret,
              "body" => finding_secret
            },
            {
              "id" => "finding-fixture-2",
              "severity" => "P2",
              "disposition" => "accepted-deferral",
              "verification_status" => "verified"
            }
          ]
        }
      ]
      github.fetch("pull_requests").last["reviews"] = [
        {
          "id" => "review-fixture-unknown",
          "provenance" => {
            "model" => "gpt-5.6-terra",
            "effort" => "UNKNOWN",
            "pricing_profile" => "standard",
            "usage" => {
              "input_tokens" => "UNKNOWN",
              "output_tokens" => "UNKNOWN",
              "cache_read_tokens" => "UNKNOWN",
              "total_tokens" => "UNKNOWN"
            }
          },
          "findings" => []
        }
      ]
      File.write(github_path, JSON.pretty_generate(github))

      stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--codex-root", codex_root, "--claude-root", claude_root,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
      assert_empty stderr

      assert_equal ["telemetry-pricing-2026-07-21-v1|USD|1"], sqlite_query(
        ledger_path, "SELECT snapshot_id, currency, version FROM pricing_snapshots"
      )
      assert_equal ["claude|6400|priced", "codex|8278|priced"], sqlite_query(
        ledger_path,
        "SELECT host_sessions.host_family, allocated_costs.cost_microusd, allocated_costs.pricing_status " \
        "FROM allocated_costs JOIN host_sessions ON host_sessions.id = allocated_costs.host_session_id " \
        "ORDER BY host_sessions.host_family"
      )
      assert_equal ["unknown|1|1"], sqlite_query(
        ledger_path,
        "SELECT pricing_status, total_cost_microusd IS NULL, input_tokens IS NULL " \
        "FROM usage_calls JOIN host_sessions ON host_sessions.id = usage_calls.host_session_id " \
        "WHERE host_sessions.link_status = 'unmatched'"
      )
      assert_equal ["4050|priced|1000|200|0|100|0|1300", "|unknown||||||"].sort.reverse, sqlite_query(
        ledger_path,
        "SELECT cost_microusd, pricing_status, input_tokens, cache_read_tokens, cache_write_tokens, " \
        "output_tokens, reasoning_output_tokens, total_tokens " \
        "FROM review_receipts ORDER BY review_ref"
      ).sort.reverse
      assert_equal ["P1|should_fix|verified", "P2|accepted-deferral|verified"], sqlite_query(
        ledger_path, "SELECT severity, disposition, verification_status FROM review_findings ORDER BY severity"
      )
      assert_equal ["batch-fixture|14678|2|0"], sqlite_query(
        ledger_path,
        "SELECT batch_id, known_cost_microusd, allocated_sessions, unknown_cost_sessions " \
        "FROM cost_scorecard"
      )
      assert_equal ["batch-fixture|2|2|1|4050|1|"], sqlite_query(
        ledger_path,
        "SELECT batch_id, reviews, findings, actionable_findings, known_review_cost_microusd, " \
        "unknown_review_costs, cost_per_actionable_finding_microusd FROM review_economics_scorecard"
      )

      scorecard_out, scorecard_err, scorecard_status = Open3.capture3(
        CLI, "scorecard", "--ledger", ledger_path, "--batch-id", "batch-fixture"
      )
      assert scorecard_status.success?, scorecard_err
      scorecard = JSON.parse(scorecard_out)
      assert_equal({ "merged" => 1, "open-pr" => 1 }, scorecard.fetch("outcomes"))
      assert_equal 14_678, scorecard.dig("costs", "known_cost_microusd")
      assert_equal "UNKNOWN", scorecard.dig("review_economics", "cost_per_actionable_finding_microusd")
      refute_includes File.binread(ledger_path), finding_secret
      refute_includes scorecard_out, finding_secret
    end
  end

  def test_linked_session_without_usage_is_allocated_as_unknown_cost
    Dir.mktmpdir("agent-coordination-ledger-empty-usage") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      codex_root = File.join(dir, "codex")
      log_dir = File.join(codex_root, "sessions", "2026", "07", "18")
      FileUtils.cp(File.join(FIXTURES, "coordination.json"), source_path)
      FileUtils.mkdir_p(log_dir)
      File.write(
        File.join(log_dir, "linked.jsonl"),
        [
          { "type" => "session_meta", "payload" => {
            "id" => "codex-fixture-session", "timestamp" => "2026-07-18T01:00:00Z",
            "cwd" => "/redacted/worktrees/ac-d-78-harvester", "pricing_profile" => "standard"
          } },
          { "type" => "turn_context", "payload" => { "model" => "gpt-5.6-sol", "effort" => "xhigh" } }
        ].map { |row| JSON.generate(row) }.join("\n")
      )

      stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--codex-root", codex_root,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
      assert_empty stderr
      assert_equal ["exact|0|unknown|1"], sqlite_query(
        ledger_path,
        "SELECT host_sessions.link_status, COUNT(usage_calls.id), allocated_costs.pricing_status, " \
        "allocated_costs.cost_microusd IS NULL FROM host_sessions " \
        "LEFT JOIN usage_calls ON usage_calls.host_session_id = host_sessions.id " \
        "JOIN allocated_costs ON allocated_costs.host_session_id = host_sessions.id " \
        "GROUP BY host_sessions.id"
      )
      assert_equal ["0|1|1"], sqlite_query(
        ledger_path,
        "SELECT known_cost_microusd, allocated_sessions, unknown_cost_sessions FROM cost_scorecard"
      )
    end
  end

  def test_rejected_review_identifiers_fall_back_and_review_economics_round_half_up
    Dir.mktmpdir("agent-coordination-ledger-review-fallback") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      github_path = File.join(dir, "github.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      FileUtils.cp(File.join(FIXTURES, "coordination.json"), source_path)
      github = JSON.parse(File.read(File.join(FIXTURES, "github.json")))
      github.fetch("pull_requests").first["reviews"] = [{
        "id" => "UNKNOWN",
        "provenance" => {
          "model" => "gpt-5.6-terra", "effort" => "high", "pricing_profile" => "standard",
          "usage" => {
            "input_tokens" => 1001, "cache_read_tokens" => 200, "cache_write_tokens" => 0,
            "output_tokens" => 100, "reasoning_output_tokens" => 0, "total_tokens" => 1301
          }
        },
        "findings" => [
          { "id" => "UNKNOWN", "disposition" => "should_fix" },
          { "disposition" => "should_fix" }
        ]
      }]
      github.fetch("pull_requests").last["reviews"] = []
      File.write(github_path, JSON.pretty_generate(github))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr
      assert_equal ["1:0"], sqlite_query(ledger_path, "SELECT review_ref FROM review_receipts")
      assert_equal ["1:0", "1:1"], sqlite_query(
        ledger_path, "SELECT finding_ref FROM review_findings ORDER BY finding_ref"
      )
      assert_equal ["4053|2|2027"], sqlite_query(
        ledger_path,
        "SELECT known_review_cost_microusd, actionable_findings, " \
        "cost_per_actionable_finding_microusd FROM review_economics_scorecard"
      )

      scorecard_out, scorecard_err, scorecard_status = Open3.capture3(
        CLI, "scorecard", "--ledger", ledger_path, "--batch-id", "batch-fixture"
      )
      assert scorecard_status.success?, scorecard_err
      unknowns = JSON.parse(scorecard_out).fetch("unknowns")
      assert unknowns.key?("unlinked_host_sessions_ledger_wide")
      refute unknowns.key?("unlinked_host_sessions")
    end
  end

  def test_coordination_refresh_without_optional_host_root_preserves_session_allocation
    Dir.mktmpdir("agent-coordination-ledger-optional-host-refresh") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      codex_root = File.join(dir, "codex")
      FileUtils.cp(File.join(FIXTURES, "coordination.json"), source_path)
      FileUtils.cp_r(File.join(FIXTURES, "codex"), codex_root)
      pricing_path = File.join(dir, "pricing.json")
      pricing = JSON.parse(File.read(File.join(ROOT, "config", "telemetry-pricing-v1.json")))
      pricing["snapshot_id"] = "telemetry-pricing-later"
      File.write(pricing_path, JSON.pretty_generate(pricing))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--codex-root", codex_root,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr
      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--pricing", pricing_path,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr

      assert_equal ["exact|1|1|8278|telemetry-pricing-2026-07-21-v1"], sqlite_query(
        ledger_path,
        "SELECT host_sessions.link_status, COUNT(DISTINCT session_lane_links.host_session_id), " \
        "COUNT(DISTINCT allocated_costs.host_session_id), allocated_costs.cost_microusd, " \
        "allocated_costs.pricing_snapshot_id " \
        "FROM host_sessions " \
        "LEFT JOIN session_lane_links ON session_lane_links.host_session_id = host_sessions.id " \
        "LEFT JOIN allocated_costs ON allocated_costs.host_session_id = host_sessions.id " \
        "WHERE host_sessions.cwd_basename = 'ac-d-78-harvester' " \
        "GROUP BY host_sessions.id"
      )
      assert_equal ["8278|1|0"], sqlite_query(
        ledger_path,
        "SELECT known_cost_microusd, allocated_sessions, unknown_cost_sessions " \
        "FROM cost_scorecard WHERE batch_id = 'batch-fixture'"
      )
    end
  end

  def test_new_batch_with_same_session_reference_invalidates_prior_exact_allocation
    Dir.mktmpdir("agent-coordination-ledger-new-ambiguity") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      codex_root = File.join(dir, "codex")
      coordination = JSON.parse(File.read(File.join(FIXTURES, "coordination.json")))
      File.write(source_path, JSON.pretty_generate(coordination))
      FileUtils.cp_r(File.join(FIXTURES, "codex"), codex_root)

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--codex-root", codex_root,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr
      coordination.fetch("batches") << {
        "batch_id" => "batch-second",
        "repo" => "shakacode/agent-coordination",
        "status" => "completed",
        "registered_at" => "2026-07-18T03:00:00Z",
        "updated_at" => "2026-07-18T04:00:00Z",
        "lanes" => [{
          "name" => "second-maker", "targets" => ["80"], "status" => "done",
          "host" => "codex", "session_id" => "codex-fixture-session"
        }]
      }
      File.write(source_path, JSON.pretty_generate(coordination))
      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-second"
      )
      assert status.success?, stderr

      assert_equal ["ambiguous|0|0"], sqlite_query(
        ledger_path,
        "SELECT host_sessions.link_status, COUNT(DISTINCT session_lane_links.host_session_id), " \
        "COUNT(DISTINCT allocated_costs.host_session_id) FROM host_sessions " \
        "LEFT JOIN session_lane_links ON session_lane_links.host_session_id = host_sessions.id " \
        "LEFT JOIN allocated_costs ON allocated_costs.host_session_id = host_sessions.id " \
        "WHERE host_sessions.cwd_basename = 'ac-d-78-harvester' " \
        "GROUP BY host_sessions.id"
      )
      assert_equal ["0|0", "0|0"], sqlite_query(
        ledger_path,
        "SELECT allocated_sessions, unknown_cost_sessions FROM cost_scorecard ORDER BY batch_id"
      )
    end
  end

  def test_cross_repo_and_multiple_pr_evidence_cannot_invent_target_outcomes # rubocop:disable Metrics/MethodLength
    Dir.mktmpdir("agent-coordination-ledger-outcome-edges") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      github_path = File.join(dir, "github.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      coordination = JSON.parse(File.read(File.join(FIXTURES, "coordination.json")))
      lanes = coordination.fetch("batches").first.fetch("lanes")
      lanes.push(
        {
          "name" => "cross-repo",
          "targets" => ["80"],
          "status" => "done",
          "pr_url" => "https://github.com/example/other/pull/80"
        },
        { "name" => "multiple-prs", "targets" => ["81"], "status" => "done" },
        { "name" => "unknown-outcome", "targets" => ["82"], "status" => "UNKNOWN" },
        { "name" => "failed-with-open-pr", "targets" => ["83"], "status" => "failed" }
      )
      File.write(source_path, JSON.pretty_generate(coordination))

      github = JSON.parse(File.read(File.join(FIXTURES, "github.json")))
      github.fetch("pull_requests").push(
        {
          "batch_id" => "batch-fixture",
          "repo" => "example/other",
          "target" => "80",
          "number" => 80,
          "url" => "https://github.com/example/other/pull/80",
          "state" => "merged"
        },
        {
          "batch_id" => "batch-fixture",
          "repo" => "shakacode/agent-coordination",
          "target" => "81",
          "number" => 181,
          "url" => "https://github.com/shakacode/agent-coordination/pull/181",
          "state" => "open"
        },
        {
          "batch_id" => "batch-fixture",
          "repo" => "shakacode/agent-coordination",
          "target" => "81",
          "number" => 281,
          "url" => "https://github.com/shakacode/agent-coordination/pull/281",
          "state" => "closed"
        },
        {
          "batch_id" => "batch-fixture",
          "repo" => "shakacode/agent-coordination",
          "target" => "83",
          "number" => 183,
          "url" => "https://github.com/shakacode/agent-coordination/pull/183",
          "state" => "open"
        }
      )
      File.write(github_path, JSON.pretty_generate(github))

      stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
      assert_equal [
        "80|done|exact|repo_mismatch",
        "81|conflicting-observations|conflicting|multiple",
        "82||unknown|none",
        "83|failed|exact|exact"
      ], sqlite_query(
        ledger_path,
        "SELECT target, outcome, outcome_evidence_status, pr_join_status " \
        "FROM target_units WHERE target IN ('80', '81', '82', '83') ORDER BY target"
      )
      assert_equal ["repo_mismatch"], sqlite_query(
        ledger_path,
        "SELECT target_pr_links.link_status FROM target_pr_links " \
        "JOIN target_units ON target_units.id = target_pr_links.target_unit_id " \
        "WHERE target_units.target = '80'"
      )
    end
  end

  def test_applied_migration_hashes_and_version_files_are_verified_on_open
    Dir.mktmpdir("agent-coordination-ledger-migrations") do |dir|
      migrations = File.join(dir, "migrations")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      FileUtils.mkdir_p(migrations)
      migration_path = File.join(migrations, "0001_fixture.sql")
      migration = <<~SQL
        CREATE TABLE schema_migrations (
          version TEXT PRIMARY KEY,
          source_sha256 TEXT NOT NULL
        );
        CREATE TABLE fixture_rows (id INTEGER PRIMARY KEY);
      SQL
      File.write(migration_path, migration)
      AgentCoord::Telemetry::Ledger.new(ledger_path, migrations_path: migrations)

      File.write(migration_path, "#{migration}\n-- changed after application\n")
      error = assert_raises(AgentCoord::Telemetry::Ledger::MigrationError) do
        AgentCoord::Telemetry::Ledger.new(ledger_path, migrations_path: migrations)
      end
      assert_equal "applied migration hash mismatch", error.message

      File.write(migration_path, migration)
      AgentCoord::Telemetry::Ledger.new(ledger_path, migrations_path: migrations)
      FileUtils.rm(migration_path)
      error = assert_raises(AgentCoord::Telemetry::Ledger::MigrationError) do
        AgentCoord::Telemetry::Ledger.new(ledger_path, migrations_path: migrations)
      end
      assert_equal "applied migration source missing", error.message
    end
  end

  def test_long_context_pricing_uses_integer_multipliers_and_unknown_profiles_are_unpriced
    catalog = AgentCoord::Telemetry::PricingCatalog.load(
      File.join(ROOT, "config", "telemetry-pricing-v1.json")
    )
    base_usage = {
      "model" => "gpt-5.6-sol",
      "pricing_profile" => "standard",
      "input_tokens" => 272_000,
      "cache_read_tokens" => 0,
      "cache_write_tokens" => 0,
      "output_tokens" => 100,
      "reasoning_output_tokens" => 0
    }

    boundary = catalog.cost(base_usage)
    assert_equal "priced", boundary.fetch("pricing_status")
    assert_equal 1_363_000, boundary.fetch("total_cost_microusd")
    assert(boundary.fetch("components").all? do |component|
      component.values.none?(Float)
    end)

    long_context = catalog.cost(base_usage.merge("input_tokens" => 272_001))
    assert_equal 2_724_510, long_context.fetch("total_cost_microusd")
    input = long_context.fetch("components").find { |component| component.fetch("component") == "input" }
    output = long_context.fetch("components").find { |component| component.fetch("component") == "output" }
    assert_equal [2, 1], input.values_at("multiplier_numerator", "multiplier_denominator")
    assert_equal [3, 2], output.values_at("multiplier_numerator", "multiplier_denominator")
    assert(long_context.fetch("components").all? { |component| component.values.none?(Float) })

    unknown = catalog.cost(base_usage.merge("pricing_profile" => "fast"))
    assert_equal "unknown", unknown.fetch("pricing_status")
    assert_nil unknown.fetch("total_cost_microusd")
    assert_empty unknown.fetch("components")
  end

  def test_claude_usage_inherits_last_known_session_metadata
    records = [
      {
        "type" => "assistant", "sessionId" => "session-retained", "pricing_profile" => "standard",
        "message" => {
          "model" => "claude-opus-4-6", "effort" => "high",
          "usage" => { "input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2 }
        }
      },
      {
        "type" => "assistant", "sessionId" => "session-retained",
        "message" => { "usage" => { "input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3 } }
      }
    ]
    parsed = AgentCoord::Telemetry::HostAdapters::Parser.new("claude").parse(
      records.map { |record| JSON.generate(record) }.join("\n"), "claude:test"
    )

    usage = parsed.fetch("sessions").fetch(0).fetch("usage")
    models = usage.map { |row| row.fetch("model") }
    efforts = usage.map { |row| row.fetch("effort") }
    profiles = usage.map { |row| row.fetch("pricing_profile") }
    assert_equal ["claude-opus-4-6", "claude-opus-4-6"], models
    assert_equal %w[high high], efforts
    assert_equal %w[standard standard], profiles
  end

  def test_pricing_catalog_rejects_wrong_unit_and_duplicate_lookup_keys
    document = JSON.parse(File.read(File.join(ROOT, "config", "telemetry-pricing-v1.json")))
    bad_unit = Marshal.load(Marshal.dump(document))
    bad_unit["unit"] = "usd_per_token"
    error = assert_raises(AgentCoord::Telemetry::Error) do
      AgentCoord::Telemetry::PricingCatalog.new(bad_unit, "a" * 64)
    end
    assert_equal "pricing unit is unsupported", error.message

    duplicate = Marshal.load(Marshal.dump(document))
    duplicate["rates"] << duplicate.fetch("rates").first.merge("provider" => "duplicate-provider")
    error = assert_raises(AgentCoord::Telemetry::Error) do
      AgentCoord::Telemetry::PricingCatalog.new(duplicate, "b" * 64)
    end
    assert_equal "pricing model/profile is duplicated", error.message

    Dir.mktmpdir("agent-coordination-pricing-snapshot") do |dir|
      ledger = AgentCoord::Telemetry::Ledger.new(File.join(dir, "telemetry.sqlite3"))
      AgentCoord::Telemetry::PricingCatalog.new(document, "a" * 64).persist(ledger)
      changed = Marshal.load(Marshal.dump(document))
      changed.fetch("rates").first.fetch("components")["input"] *= 2
      error = assert_raises(AgentCoord::Telemetry::Error) do
        AgentCoord::Telemetry::PricingCatalog.new(changed, "b" * 64).persist(ledger)
      end
      assert_equal "pricing snapshot source hash mismatch", error.message
      assert_equal 5_000_000, ledger.first(
        "SELECT rate_microusd_per_million_tokens AS rate FROM pricing_rates " \
        "WHERE snapshot_id = ? AND model = ? AND profile = ? AND component = ?",
        [document.fetch("snapshot_id"), "gpt-5.6-sol", "standard", "input"]
      ).fetch("rate")
    end
  end

  private

  def sqlite_query(ledger_path, sql)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-rsqlite3", "-e",
      "db = SQLite3::Database.new(ARGV.shift); puts db.execute(ARGV.shift).map { |row| row.join('|') }",
      ledger_path, sql
    )
    assert status.success?, "SQLite query failed: #{stderr}"
    stdout.lines(chomp: true)
  end

  def coordination_fixture
    {
      "batches" => [
        {
          "batch_id" => "batch-fixture",
          "repo" => "shakacode/agent-coordination",
          "status" => "completed",
          "registered_at" => "2026-07-18T01:00:00Z",
          "updated_at" => "2026-07-18T02:00:00Z",
          "lanes" => [
            {
              "name" => "maker",
              "owner" => "worker-fixture",
              "targets" => ["78"],
              "status" => "done"
            }
          ]
        }
      ],
      "claims" => [],
      "events" => [],
      "heartbeats" => [],
      "degraded" => []
    }
  end
end
