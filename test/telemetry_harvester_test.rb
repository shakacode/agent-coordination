# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

require_relative "../lib/agent_coordination/ledger"
require_relative "../lib/agent_coordination/pricing"
require_relative "../lib/agent_coordination/harvester"

class TelemetryHarvesterTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  ROOT = File.expand_path("..", __dir__)
  CLI = File.join(ROOT, "bin", "agent-coord-harvest")
  COORD_CLI = File.join(ROOT, "bin", "agent-coord")
  FIXTURES = File.join(ROOT, "test", "fixtures", "telemetry")
  HARVESTER = AgentCoord::Telemetry::Harvester
  HOST_ADAPTERS = AgentCoord::Telemetry::HostAdapters
  # The codepoint window the control-character pins compare over: C0, DEL, and
  # C1, which together cover every range any of the sanitizers targets.
  CONTROL_CODEPOINTS = (0x00..0x9F).to_a.freeze
  CORPUS_BATCH = "event-corpus-batch"
  CORPUS_REPO = "shakacode/agent-coordination"
  CORPUS_TARGET = "112"
  # Variables that could point the CLI at a backend other than the temp
  # `--state-root` the corpus passes. All are cleared: a developer (or CI) with
  # a live `AGENT_COORD_API_URL` and token exported must not have the corpus
  # silently talk to the real coordination backend over the network.
  CORPUS_BACKEND_ENV = %w[
    AGENT_COORD_API_TOKEN AGENT_COORD_API_URL AGENT_COORD_BACKEND AGENT_COORD_ENV_FILE
    AGENT_COORD_LOCAL AGENT_COORD_REF AGENT_COORD_STATE_ROOT AGENT_COORD_STATUS_STATE_ROOT
  ].freeze
  # Keeps the corpus off the developer's real coordination state and config, and
  # off any backend: the corpus must exercise the local state root only.
  CORPUS_ENV = CORPUS_BACKEND_ENV.to_h { |name| [name, nil] }.merge(
    "AGENT_COORD_MACHINE_ID" => "corpus-machine",
    "AGENT_COORD_SESSION_ID" => nil,
    # Not read by bin/agent-coord today, but exported in some agent shells and
    # cleared here so an ambient policy cannot reach the corpus either.
    "AGENT_COORD_POLICY" => nil,
    "CODEX_THREAD_ID" => nil
  ).freeze

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

  def test_named_batch_harvest_matches_non_ascii_id_under_an_ascii_locale
    Dir.mktmpdir("agent-coordination-ledger-non-ascii-batch") do |dir|
      batch_id = "batch-café"
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      source = coordination_fixture.tap { |document| document.fetch("batches").first["batch_id"] = batch_id }
      File.write(source_path, JSON.generate(source))

      ["C.UTF-8", "C"].each do |locale|
        stdout, stderr, status = Open3.capture3(
          { "LC_ALL" => locale, "LANG" => locale },
          CLI, "harvest", "--ledger", ledger_path,
          "--coordination-json", source_path, "--batch-id", batch_id
        )

        assert status.success?, "#{locale} harvest failed:\n#{stdout}\n#{stderr}"
        assert_equal "harvested batches=1 targets=1 usage=0\n", stdout, locale
        assert_empty stderr, locale
        assert_equal [batch_id], sqlite_query(ledger_path, "SELECT batch_id FROM batches"), locale
      end
    end
  end

  def test_scorecard_matches_non_ascii_batch_id_under_an_ascii_locale
    Dir.mktmpdir("agent-coordination-scorecard-non-ascii-batch") do |dir|
      batch_id = "batch-café"
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      source = coordination_fixture.tap { |document| document.fetch("batches").first["batch_id"] = batch_id }
      File.write(source_path, JSON.generate(source))

      _stdout, stderr, status = Open3.capture3(
        { "LC_ALL" => "C.UTF-8", "LANG" => "C.UTF-8" },
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", batch_id
      )
      assert status.success?, stderr

      control_out, control_err, control_status = Open3.capture3(
        { "LC_ALL" => "C.UTF-8", "LANG" => "C.UTF-8" },
        CLI, "scorecard", "--ledger", ledger_path, "--batch-id", batch_id
      )
      assert control_status.success?, control_err
      assert_empty control_err
      assert_equal batch_id, JSON.parse(control_out).fetch("batch_id")

      stdout, stderr, status = Open3.capture3(
        { "LC_ALL" => "C", "LANG" => "C" },
        CLI, "scorecard", "--ledger", ledger_path, "--batch-id", batch_id
      )

      assert status.success?, "scorecard failed:\n#{stdout}\n#{stderr}"
      assert_empty stderr
      assert_equal batch_id, JSON.parse(stdout).fetch("batch_id")
    end
  end

  def test_date_options_reject_invalid_utf8_before_date_parsing
    Dir.mktmpdir("agent-coordination-invalid-date-argv") do |dir|
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      File.write(source_path, JSON.generate(coordination_fixture))

      stdout, stderr, status = Open3.capture3(
        { "LC_ALL" => "C", "LANG" => "C" },
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path,
        "--from", "2026-07-\xFF".b, "--to", "2026-07-18"
      )

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "command-line argument must be valid UTF-8"
      refute_includes stderr, "date range must use YYYY-MM-DD"
      refute_includes stderr, "lib/agent_coordination/harvester.rb:"
    end
  end

  def test_invalid_command_token_is_rejected_as_text_without_a_backtrace
    stdout, stderr, status = Open3.capture3(
      { "LC_ALL" => "C", "LANG" => "C" }, CLI, "\xFFharvest".b
    )

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "command-line argument must be valid UTF-8"
    refute_includes stderr, "bin/agent-coord-harvest:"
    refute_includes stderr, "lib/agent_coordination/argv_encoding.rb:"
  end

  def test_invalid_batch_id_is_rejected_cleanly_by_both_commands
    invalid = "batch-\xFF".b
    {
      "harvest" => ["harvest", "--batch-id", invalid],
      "scorecard" => ["scorecard", "--batch-id", invalid]
    }.each do |command, argv|
      stdout, stderr, status = Open3.capture3(
        { "LC_ALL" => "C", "LANG" => "C" }, CLI, *argv
      )

      refute status.success?, command
      assert_empty stdout, command
      assert_includes stderr, "agent-coord-harvest: command-line argument must be valid UTF-8", command
      refute_includes stderr, "bin/agent-coord-harvest:", command
      refute_includes stderr, "lib/agent_coordination/argv_encoding.rb:", command
    end
  end

  def test_ambiguous_path_option_precedes_invalid_path_encoding
    Dir.mktmpdir("agent-coordination-ambiguous-path-argv") do |dir|
      stdout, stderr, status = Open3.capture3(
        { "LC_ALL" => "C", "LANG" => "C" },
        CLI, "harvest", "--ledger", File.join(dir, "telemetry.sqlite3"),
        "--co", "/tmp/coordination-\xE9.json".b, "--batch-id", "batch-fixture"
      )

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "agent-coord-harvest: ambiguous option: --co"
      refute_includes stderr, "command-line argument must be valid UTF-8"
      refute_includes stderr, "lib/agent_coordination/harvester.rb:"
    end
  end

  def test_harvester_cli_transcodes_declared_batch_encoding_and_retags_binary
    Dir.mktmpdir("agent-coordination-harvester-argv-encodings") do |dir|
      batch_id = "batch-café"
      source_path = File.join(dir, "coordination.json")
      source = coordination_fixture
      source.fetch("batches").first["batch_id"] = batch_id
      File.write(source_path, JSON.generate(source))

      {
        "declared latin-1" => "batch-caf\xE9".b.force_encoding(Encoding::ISO_8859_1),
        "binary" => batch_id.b
      }.each_with_index do |(label, argument), index|
        stdout = StringIO.new
        stderr = StringIO.new
        code = AgentCoord::Telemetry::CLI.run(
          ["harvest", "--ledger", File.join(dir, "telemetry-#{index}.sqlite3"),
           "--coordination-json", source_path, "--batch-id", argument],
          stdout:, stderr:
        )

        assert_equal 0, code, "#{label}: #{stderr.string}"
        assert_equal "harvested batches=1 targets=1 usage=0\n", stdout.string, label
        assert_empty stderr.string, label
      end
    end
  end

  def test_harvester_path_options_keep_their_original_bytes
    typed = "/tmp/caf\xE9".b.force_encoding(Encoding::ISO_8859_1)
    cases = {
      "harvest separate" => ["harvest", "--ledger", typed],
      "harvest equals" => ["harvest", "--ledger=#{typed}".b.force_encoding(typed.encoding)],
      "harvest abbreviated" => ["harvest", "--led", typed],
      "scorecard separate" => ["scorecard", "--ledger", typed],
      "scorecard equals" => ["scorecard", "--ledger=#{typed}".b.force_encoding(typed.encoding)]
    }

    cases.each do |label, argv|
      normalized = AgentCoord::Telemetry::CLI.normalized_argv(argv)

      assert_equal argv.last.b, normalized.last.b, label
      assert_equal argv.last.encoding, normalized.last.encoding, label
    end

    batch_id = "batch-caf\xE9".b.force_encoding(Encoding::ISO_8859_1)
    normalized = AgentCoord::Telemetry::CLI.normalized_argv(["scorecard", "--batch-id", batch_id])
    assert_equal "batch-café", normalized.last
    assert_equal Encoding::UTF_8, normalized.last.encoding
  end

  def test_non_utf8_path_bytes_reach_the_filesystem_unchanged
    Dir.mktmpdir("agent-coordination-harvester-path-argv") do |dir|
      source_path = "#{dir}/coordination-café.json".b.force_encoding(Encoding::ISO_8859_1)
      File.binwrite(source_path, JSON.generate(coordination_fixture))

      {
        "separate" => ["--coordination-json", source_path],
        "equals" => ["--coordination-json=#{source_path}".b.force_encoding(source_path.encoding)]
      }.each_with_index do |(label, path_argv), index|
        ledger_path = File.join(dir, "telemetry-#{index}.sqlite3")
        stdout = StringIO.new
        stderr = StringIO.new
        code = AgentCoord::Telemetry::CLI.run(
          ["harvest", "--ledger", ledger_path, *path_argv, "--batch-id", "batch-fixture"],
          stdout:, stderr:
        )

        assert_equal 0, code, "#{label}: #{stderr.string}"
        assert_equal "harvested batches=1 targets=1 usage=0\n", stdout.string, label
        assert_empty stderr.string, label
        assert File.file?(ledger_path), label
      end
    end
  end

  def test_invalid_utf8_in_values_and_keys_is_rejected_before_ingest
    Dir.mktmpdir("agent-coordination-ledger-invalid-utf8") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      File.write(source_path, JSON.generate(coordination_fixture))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr
      original_counts = sqlite_query(
        ledger_path,
        "SELECT (SELECT COUNT(*) FROM batches), (SELECT COUNT(*) FROM events), " \
        "(SELECT COUNT(*) FROM source_artifacts)"
      )

      invalid_utf8_documents.each do |location, build_document|
        File.binwrite(source_path, build_document.call)
        stdout, stderr, status = Open3.capture3(
          CLI, "harvest", "--ledger", ledger_path,
          "--coordination-json", source_path, "--batch-id", "batch-fixture"
        )

        refute status.success?, "invalid UTF-8 in a JSON #{location} must not harvest successfully"
        assert_empty stdout
        assert_equal "agent-coord-harvest: coordination JSON contains invalid UTF-8: #{source_path}\n", stderr
        assert_equal original_counts, sqlite_query(
          ledger_path,
          "SELECT (SELECT COUNT(*) FROM batches), (SELECT COUNT(*) FROM events), " \
          "(SELECT COUNT(*) FROM source_artifacts)"
        ), "invalid UTF-8 in a JSON #{location} partially mutated the ledger"
      end
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

  def test_rejected_batch_records_an_idempotent_ingestion_error_and_refresh_clears_it # rubocop:disable Metrics/MethodLength
    Dir.mktmpdir("agent-coordination-ledger-invalid-batch") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      rejected_id = "batch\u009Bfixture"
      source = coordination_fixture
      rejected_batch = Marshal.load(Marshal.dump(source.fetch("batches").first))
      rejected_batch["batch_id"] = rejected_id
      source.fetch("batches") << rejected_batch
      source.fetch("claims") << {
        "batch_id" => rejected_id, "repo" => "shakacode/agent-coordination",
        "target" => "78", "status" => "released", "terminal" => "done"
      }
      source.fetch("events") << {
        "id" => "event-invalid-batch", "batch_id" => rejected_id,
        "repo" => "shakacode/agent-coordination", "target" => "78",
        "type" => "lane_closed", "at" => "2026-07-18T01:30:00Z"
      }
      File.write(source_path, JSON.generate(source))

      2.times do
        stdout, stderr, status = Open3.capture3(
          CLI, "harvest", "--ledger", ledger_path,
          "--coordination-json", source_path, "--batch-id", rejected_id
        )
        assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
        assert_equal "harvested batches=0 targets=0 usage=0\n", stdout
        assert_empty stderr
      end

      assert_equal ["0|0|0|0|0"], sqlite_query(
        ledger_path,
        "SELECT (SELECT COUNT(*) FROM batches), (SELECT COUNT(*) FROM lanes), " \
        "(SELECT COUNT(*) FROM target_units), (SELECT COUNT(*) FROM claims), " \
        "(SELECT COUNT(*) FROM events)"
      )
      errors = sqlite_query(
        ledger_path,
        "SELECT source_artifacts.source_ref, ingestion_errors.record_ordinal, ingestion_errors.reason " \
        "FROM ingestion_errors JOIN source_artifacts ON source_artifacts.id = ingestion_errors.source_artifact_id"
      )
      assert_equal 1, errors.length
      assert_match(/\Acoordination:[0-9a-f]{16}\|2\|invalid_record\z/, errors.first)

      rejected_batch["batch_id"] = "batch-refreshed"
      source.fetch("claims").first["batch_id"] = "batch-refreshed"
      source.fetch("events").first["batch_id"] = "batch-refreshed"
      File.write(source_path, JSON.generate(source))
      stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-refreshed"
      )
      assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
      assert_equal "harvested batches=1 targets=1 usage=0\n", stdout
      assert_empty stderr
      assert_equal ["1|1|1|1|1|0"], sqlite_query(
        ledger_path,
        "SELECT (SELECT COUNT(*) FROM batches), (SELECT COUNT(*) FROM lanes), " \
        "(SELECT COUNT(*) FROM target_units), (SELECT COUNT(*) FROM claims), " \
        "(SELECT COUNT(*) FROM events), (SELECT COUNT(*) FROM ingestion_errors)"
      )
    end
  end

  def test_rejected_pull_request_records_an_idempotent_ingestion_error_and_refresh_clears_it # rubocop:disable Metrics/MethodLength
    Dir.mktmpdir("agent-coordination-ledger-invalid-pr") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      github_path = File.join(dir, "github.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      File.write(source_path, JSON.generate(coordination_fixture))
      github = {
        "pull_requests" => [
          {
            "batch_id" => "batch-fixture", "repo" => "shakacode/agent-coordination", "target" => "78",
            "number" => 178, "url" => "https://github.com/shakacode/agent-coordination/pull/178",
            "state" => "open", "reviews" => [{ "id" => "review-retained", "findings" => [] }]
          },
          {
            "batch_id" => "batch-fixture", "repo" => "shakacode/agent-coordination", "target" => "78",
            "number" => 179, "url" => "https://github.com/shakacode/agent-coordination/pull/179",
            "state" => "open\u009B", "reviews" => [{ "id" => "review-rejected", "findings" => [] }]
          }
        ]
      }
      File.write(github_path, JSON.generate(github))

      2.times do
        stdout, stderr, status = Open3.capture3(
          CLI, "harvest", "--ledger", ledger_path,
          "--coordination-json", source_path, "--github-json", github_path,
          "--batch-id", "batch-fixture"
        )
        assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
        assert_equal "harvested batches=1 targets=1 usage=0\n", stdout
        assert_empty stderr
      end

      assert_equal ["178"], sqlite_query(ledger_path, "SELECT number FROM github_prs")
      assert_equal ["1"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM review_receipts")
      errors = sqlite_query(
        ledger_path,
        "SELECT source_artifacts.source_ref, ingestion_errors.record_ordinal, ingestion_errors.reason " \
        "FROM ingestion_errors JOIN source_artifacts ON source_artifacts.id = ingestion_errors.source_artifact_id"
      )
      assert_equal 1, errors.length
      assert_match(/\Agithub:[0-9a-f]{16}\|2\|invalid_record\z/, errors.first)

      github.fetch("pull_requests").last["state"] = "open"
      File.write(github_path, JSON.generate(github))
      stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--github-json", github_path,
        "--batch-id", "batch-fixture"
      )
      assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
      assert_equal "harvested batches=1 targets=1 usage=0\n", stdout
      assert_empty stderr
      assert_equal %w[178 179], sqlite_query(ledger_path, "SELECT number FROM github_prs ORDER BY number")
      assert_equal ["2"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM review_receipts")
      assert_empty sqlite_query(ledger_path, "SELECT id FROM ingestion_errors")
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

      assert_equal ["78|done|1", "79|open-pr|0"], sqlite_query(
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
        "SELECT (SELECT COUNT(*) FROM target_pr_links), " \
        "(SELECT COUNT(*) FROM review_receipts WHERE target_unit_id IS NULL)"
      )

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr
      assert_equal ["2|1"], sqlite_query(
        ledger_path,
        "SELECT (SELECT COUNT(*) FROM target_pr_links), " \
        "(SELECT COUNT(*) FROM review_receipts WHERE target_unit_id IS NULL)"
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
        "id" => "event-terminal-done", "batch_id" => "batch-fixture",
        "repo" => "shakacode/agent-coordination", "target" => "80",
        "type" => "lane_closed", "terminal" => "done", "at" => "2026-07-18T02:00:00Z"
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
      assert_equal ["78|failed", "80|done"], sqlite_query(
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

      assert_equal ["78|done|exact", "79|open-pr|exact"], sqlite_query(
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
      assert_equal({ "done" => 1, "open-pr" => 1 }, scorecard.fetch("outcomes"))
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

  def test_host_adapter_controls_cannot_launder_session_metadata # rubocop:disable Metrics/MethodLength
    controls = {
      "NUL" => 0x00,
      "TAB in the interior" => 0x09,
      "VT" => 0x0B,
      "FF" => 0x0C,
      "DEL" => 0x7F
    }
    (0x80..0x9F).each { |codepoint| controls[format("C1 0x%02X", codepoint)] = codepoint }

    controls.each do |label, codepoint|
      character = [codepoint].pack("U")
      dirty = lambda do |value|
        if codepoint == 0x09
          midpoint = value.length / 2
          "#{value[0...midpoint]}#{character}#{value[midpoint..]}"
        else
          "#{value}#{character}"
        end
      end
      parsed = parse_codex_host_session(
        cwd: dirty.call("/redacted/work"),
        model: dirty.call("gpt-5.6-sol"),
        effort: dirty.call("high"),
        pricing_profile: dirty.call("standard")
      )
      assert_empty parsed.fetch("errors"), "#{label} should be valid JSON input"
      session = parsed.fetch("sessions").fetch(0)
      usage = session.fetch("usage").fetch(0)

      %w[cwd_basename cwd_sha256 model effort pricing_profile].each do |field|
        assert_nil session.fetch(field), "#{label} was laundered into host_sessions.#{field}"
      end
      %w[model effort pricing_profile].each do |field|
        assert_nil usage.fetch(field), "#{label} was laundered into usage_calls.#{field}"
      end
    end

    surrounding_whitespace = "\t \r\n"
    parsed = parse_codex_host_session(
      cwd: "#{surrounding_whitespace}/redacted/work#{surrounding_whitespace}",
      model: "#{surrounding_whitespace}gpt-5.6-sol#{surrounding_whitespace}",
      effort: "#{surrounding_whitespace}high#{surrounding_whitespace}",
      pricing_profile: "#{surrounding_whitespace}standard#{surrounding_whitespace}"
    )
    session = parsed.fetch("sessions").fetch(0)
    assert_equal ["work", "gpt-5.6-sol", "high", "standard"],
                 session.values_at("cwd_basename", "model", "effort", "pricing_profile")
    assert_equal 64, session.fetch("cwd_sha256").length
    assert_equal ["gpt-5.6-sol", "high", "standard"],
                 session.fetch("usage").fetch(0).values_at("model", "effort", "pricing_profile")

    assert_same HOST_ADAPTERS::INGEST_CONTROL_CHARACTERS, HARVESTER::INGEST_CONTROL_CHARACTERS
    assert_same HOST_ADAPTERS::INGEST_SURROUNDING_WHITESPACE, HARVESTER::INGEST_SURROUNDING_WHITESPACE
  end

  def test_rejected_present_metadata_clears_last_known_session_values # rubocop:disable Metrics/MethodLength
    nul = "\u0000"
    usage = { "input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2 }
    codex_records = [
      {
        "type" => "session_meta",
        "payload" => {
          "id" => "metadata-clear", "cwd" => "/redacted/work", "pricing_profile" => "standard"
        }
      },
      { "type" => "turn_context", "payload" => { "model" => "gpt-5.6-sol", "effort" => "high" } },
      { "type" => "event_msg", "payload" => {
        "type" => "token_count", "info" => { "last_token_usage" => usage }
      } },
      { "type" => "turn_context", "payload" => {} },
      { "type" => "event_msg", "payload" => {
        "type" => "token_count", "info" => { "last_token_usage" => usage }
      } },
      {
        "type" => "session_meta",
        "payload" => {
          "id" => "metadata-clear", "cwd" => "/redacted/work#{nul}",
          "pricing_profile" => "standard#{nul}"
        }
      },
      {
        "type" => "turn_context",
        "payload" => { "model" => "gpt-5.6-sol#{nul}", "effort" => "high#{nul}" }
      },
      { "type" => "event_msg", "payload" => {
        "type" => "token_count", "info" => { "last_token_usage" => usage }
      } }
    ]
    claude_records = [
      {
        "type" => "assistant", "sessionId" => "metadata-clear", "cwd" => "/redacted/work",
        "pricing_profile" => "standard",
        "message" => { "model" => "claude-opus-4-6", "effort" => "high", "usage" => usage }
      },
      {
        "type" => "assistant", "sessionId" => "metadata-clear", "message" => { "usage" => usage }
      },
      {
        "type" => "assistant", "sessionId" => "metadata-clear", "cwd" => "/redacted/work#{nul}",
        "pricing_profile" => "standard#{nul}",
        "message" => {
          "model" => "claude-opus-4-6#{nul}", "effort" => "high#{nul}", "usage" => usage
        }
      }
    ]

    { "codex" => codex_records, "claude" => claude_records }.each do |host_family, records|
      parsed = HOST_ADAPTERS::Parser.new(host_family).parse(
        records.map { |record| JSON.generate(record) }.join("\n"), "#{host_family}:metadata-clear"
      )
      assert_empty parsed.fetch("errors"), "#{host_family} control metadata should remain valid JSON"
      session = parsed.fetch("sessions").fetch(0)
      clean_usage, inherited_usage, rejected_usage = session.fetch("usage")
      expected_model = host_family == "codex" ? "gpt-5.6-sol" : "claude-opus-4-6"

      assert_equal [expected_model, "high", "standard"],
                   clean_usage.values_at("model", "effort", "pricing_profile")
      assert_equal [expected_model, "high", "standard"],
                   inherited_usage.values_at("model", "effort", "pricing_profile"),
                   "#{host_family} should inherit metadata when a field is absent"
      assert_equal [nil, nil, nil], rejected_usage.values_at("model", "effort", "pricing_profile"),
                   "#{host_family} reused metadata from before a rejected present value"
      assert_equal [nil, nil, nil, nil, nil],
                   session.values_at("cwd_basename", "cwd_sha256", "model", "effort", "pricing_profile")
    end
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

  # --- issue #112: event retention -------------------------------------------

  # The real deliverable of #112 is the drift guard, not the current list. The
  # CLI's emitted event-type set is derived from bin/agent-coord itself, so a
  # new emitted type fails here until the harvester either ingests it or names
  # it in EXCLUDED_CLI_EVENT_TYPES. The write-time enum mirrors are pinned in
  # the same test because they drift for the same reason and from the same file.
  def test_harvester_ingest_contract_tracks_bin_agent_coord
    emitted = cli_emitted_event_types
    unclassified = emitted - HARVESTER::CLI_EVENT_TYPES - HARVESTER::EXCLUDED_CLI_EVENT_TYPES
    assert_empty unclassified,
                 "bin/agent-coord emits event types the harvester does not classify: " \
                 "#{unclassified.inspect}. Add them to CLI_LIFECYCLE_EVENT_TYPES / " \
                 "CLI_TERMINAL_EVENT_TYPES / CLI_TYPED_EVENT_TYPES, or name them in " \
                 "EXCLUDED_CLI_EVENT_TYPES with a reason."
    assert_empty HARVESTER::CLI_EVENT_TYPES - emitted,
                 "harvester claims CLI event types bin/agent-coord no longer emits"
    assert_empty HARVESTER::EXCLUDED_CLI_EVENT_TYPES - emitted,
                 "EXCLUDED_CLI_EVENT_TYPES names a type the CLI does not emit"

    # The exclusion list must not be able to switch this guard off. Naming every
    # emitted type would collapse EVENT_TYPES back to the historical-only list --
    # reproducing #112 exactly -- while every assertion above still passed.
    refute_empty emitted - HARVESTER::EXCLUDED_CLI_EVENT_TYPES,
                 "EXCLUDED_CLI_EVENT_TYPES excludes every emitted type, which disables ingest entirely"
    # The self-emitted types are the backbone of the lifecycle and can never be
    # excluded; only an operator-supplied signal could ever earn an exclusion.
    always_ingested = HARVESTER::CLI_LIFECYCLE_EVENT_TYPES + HARVESTER::CLI_TERMINAL_EVENT_TYPES
    assert_empty always_ingested & HARVESTER::EXCLUDED_CLI_EVENT_TYPES,
                 "the CLI's own lifecycle/terminal emissions must never be excluded from ingest"

    not_ingested = emitted - HARVESTER::EXCLUDED_CLI_EVENT_TYPES - HARVESTER::EVENT_TYPES
    assert_empty not_ingested, "EVENT_TYPES would clamp these CLI event types to NULL: #{not_ingested.inspect}"

    # Floor, not an exact count: the CLI legitimately growing a type must fail
    # the drift assertions above with their specific message, not here. This
    # only catches a derivation that silently stopped finding types at all.
    assert_operator emitted.length, :>=, 8, "derived CLI event-type set looks truncated: #{emitted.inspect}"
    assert_includes emitted, "lane_closed"

    load_agent_coord_cli
    assert_equal AgentCoord::ERROR_SEVERITIES, HARVESTER::EVENT_SEVERITIES,
                 "EVENT_SEVERITIES no longer mirrors AgentCoord::ERROR_SEVERITIES"
    assert_equal AgentCoord::HUMAN_INTERVENTION_KINDS, HARVESTER::EVENT_KINDS,
                 "EVENT_KINDS no longer mirrors AgentCoord::HUMAN_INTERVENTION_KINDS"
    assert_equal AgentCoord::HELP_REQUESTED_REASONS, HARVESTER::EVENT_REASONS,
                 "EVENT_REASONS no longer mirrors AgentCoord::HELP_REQUESTED_REASONS"
  end

  # End-to-end corpus: drive the real CLI so it writes one event of every type it
  # emits -- including the lifecycle events nothing records explicitly -- then
  # harvest that state and prove nothing is clamped to NULL on the way in. This
  # doubles as the batch's QA evidence, so it prints the retained rows.
  def test_cli_event_corpus_survives_harvest_with_event_type_and_signal_fields
    Dir.mktmpdir("agent-coordination-ledger-event-corpus") do |dir| # rubocop:disable Metrics/BlockLength
      emitted, source_path = record_cli_event_corpus(dir)
      assert_equal cli_emitted_event_types.sort, emitted,
                   "the corpus did not exercise every event type the CLI emits"
      # The corpus ran against its temp --state-root, not an ambient backend:
      # a network backend would leave nothing on local disk here.
      on_disk = Dir.glob(File.join(dir, "state", "events", CORPUS_BATCH, "*.json"))
      refute_empty on_disk, "the corpus wrote no events under its temp --state-root"
      assert_equal emitted, on_disk.map { |path| JSON.parse(File.read(path)).fetch("type") }.sort

      ledger_path = File.join(dir, "telemetry.sqlite3")
      stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", CORPUS_BATCH
      )
      assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"

      retained = sqlite_query(
        ledger_path,
        "SELECT COALESCE(event_type, 'NULL'), COALESCE(event_type_raw, 'NULL'), " \
        "COALESCE(severity, '-'), COALESCE(category, '-'), COALESCE(kind, '-'), COALESCE(reason, '-') " \
        "FROM events ORDER BY event_type_raw"
      )
      puts "\nissue #112 corpus -- events(event_type|event_type_raw|severity|category|kind|reason):"
      retained.each { |row| puts "  #{row}" }

      assert_equal emitted, sqlite_query(ledger_path, "SELECT event_type FROM events ORDER BY event_type"),
                   "harvest clamped a CLI-emitted event type to NULL"
      assert_equal ["0"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM events WHERE event_type IS NULL")
      assert_empty sqlite_query(ledger_path, "SELECT * FROM event_type_drift")

      assert_equal ["error|P1|harvest-corpus"], sqlite_query(
        ledger_path, "SELECT event_type, severity, category FROM events WHERE severity IS NOT NULL"
      )
      assert_equal ["human_intervention|takeover"], sqlite_query(
        ledger_path, "SELECT event_type, kind FROM events WHERE kind IS NOT NULL"
      )
      assert_equal ["help_requested|question"], sqlite_query(
        ledger_path, "SELECT event_type, reason FROM events WHERE reason IS NOT NULL"
      )
      # escalation_requested's from_route/to_route/evidence are deliberately not
      # retained: evidence is free prose, and the routes are unbounded free text
      # duplicating the dimension host_sessions already carries. #143 needs only
      # the count, which event_type provides.
      columns = sqlite_query(ledger_path, "SELECT name FROM pragma_table_info('events')")
      assert_equal ["escalation_requested"], sqlite_query(
        ledger_path, "SELECT event_type FROM events WHERE event_type = 'escalation_requested'"
      )
      assert_empty columns & %w[from_route to_route evidence]
    end
  end

  # The corpus drives the real CLI, so it must be provably pinned to its temp
  # `--state-root` and never to an ambient backend. The scrub list is derived
  # from bin/agent-coord rather than restated, so a newly read AGENT_COORD_*
  # variable fails here instead of silently letting a live `AGENT_COORD_API_URL`
  # and token redirect the corpus onto the real coordination backend.
  def test_event_corpus_is_isolated_from_ambient_backend_configuration
    read_by_cli = File.read(COORD_CLI).scan(/AGENT_COORD_[A-Z_]+/).uniq
    unscrubbed = read_by_cli - CORPUS_ENV.keys
    assert_empty unscrubbed,
                 "bin/agent-coord reads #{unscrubbed.inspect}, which the corpus does not neutralize. " \
                 "Add each to CORPUS_BACKEND_ENV (if it can select a backend or state root) or to CORPUS_ENV."
    CORPUS_BACKEND_ENV.each do |name|
      assert_nil CORPUS_ENV.fetch(name), "#{name} must be cleared for the corpus, not given a value"
    end
    # The corpus also passes --state-root explicitly rather than relying on the
    # cleared environment alone. That the state actually lands there is asserted
    # by the corpus test itself, which already pays for the CLI run.
    assert_includes corpus_commands("/tmp/state-root-probe").first, "--state-root"
  end

  # 0001-0003 are already applied in existing ledgers and are hash-pinned, so
  # 0004 has to be purely additive. Open a ledger that only knows 0001-0003,
  # populate it, then reopen against the full migration set: the older hashes
  # must still verify and the pre-existing rows must simply gain NULL columns.
  def test_event_retention_migration_applies_additively_to_an_existing_ledger
    Dir.mktmpdir("agent-coordination-ledger-migration") do |dir|
      ledger_path = File.join(dir, "telemetry.sqlite3")
      seed_ledger_without_event_retention(dir, ledger_path)
      before = sqlite_query(ledger_path, "SELECT version FROM schema_migrations ORDER BY version")
      assert_equal %w[0001_initial 0002_host_usage 0003_pricing_scorecards], before

      AgentCoord::Telemetry::Ledger.new(ledger_path)

      assert_equal before + ["0004_event_type_retention"],
                   sqlite_query(ledger_path, "SELECT version FROM schema_migrations ORDER BY version")
      assert_equal ["pre-existing|lane_closed|NULL|NULL|NULL|NULL|NULL"], sqlite_query(
        ledger_path,
        "SELECT event_ref, event_type, COALESCE(event_type_raw, 'NULL'), COALESCE(severity, 'NULL'), " \
        "COALESCE(category, 'NULL'), COALESCE(kind, 'NULL'), COALESCE(reason, 'NULL') FROM events"
      )
    end
  end

  # Regression for the review finding on PR #155. `event_type_raw` originally
  # reused `known()`, which rejects an oversized string, one carrying control
  # characters, and the literal "UNKNOWN". Such a row landed with BOTH columns
  # NULL and disappeared from `event_type_drift` -- the same silent loss #112 is
  # about. The column must sanitize, never reject.
  def test_event_type_raw_is_null_only_when_the_source_carried_no_type
    Dir.mktmpdir("agent-coordination-ledger-raw-type") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      source = coordination_fixture
      unsanitizable_event_types.each_with_index do |(label, type), index|
        event = {
          "id" => "event-raw-#{label}", "batch_id" => "batch-fixture",
          "repo" => "shakacode/agent-coordination", "target" => "78",
          "at" => "2026-07-18T01:3#{index}:00Z"
        }
        event["type"] = type unless type == :absent
        source["events"] << event
      end
      File.write(source_path, JSON.generate(source))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr

      # The invariant as a query: a NULL raw type exactly when the source event
      # carried no usable type.
      typeless = unsanitizable_event_types.count { |_, type| type == :absent || type.to_s.strip.empty? }
      assert_equal [typeless.to_s],
                   sqlite_query(ledger_path, "SELECT COUNT(*) FROM events WHERE event_type_raw IS NULL"),
                   "an event that carried a type was stored with a NULL event_type_raw"
      assert_equal ["0"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM events WHERE event_type_raw = ''")

      # Every type-bearing unrecognized event stays visible in the drift view.
      drift = sqlite_query(ledger_path, "SELECT event_type_raw FROM event_type_drift ORDER BY event_type_raw")
      type_bearing = unsanitizable_event_types.count { |_, type| type != :absent && !type.to_s.strip.empty? }
      assert_equal type_bearing, drift.length, "a type-bearing event escaped event_type_drift: #{drift.inspect}"
      assert_includes drift, "UNKNOWN", "the literal UNKNOWN type must be stored verbatim"

      # Two distinct oversized types must not collapse into one drift row.
      long_rows = drift.select { |row| row.start_with?("x" * 32) }
      assert_equal 2, long_rows.length, "distinct oversized types collapsed: #{long_rows.inspect}"
      assert_equal 2, long_rows.uniq.length
      long_rows.each do |row|
        assert_operator row.bytesize, :<=, HARVESTER::SIGNAL_MAX_BYTES
        assert_match(/~[0-9a-f]{12}\z/, row, "a modified raw type must carry its origin digest")
      end
      # Control characters never reach the stored column.
      assert_empty sqlite_query(
        ledger_path,
        "SELECT event_type_raw FROM events WHERE event_type_raw GLOB '*' || char(27) || '*' " \
        "OR event_type_raw GLOB '*' || char(1) || '*'"
      )
    end
  end

  # The typed vocabulary exists in three copies: the CLI constants, the Ruby
  # mirrors, and the SQL CHECK literals in 0004. The drift test pins CLI-vs-Ruby;
  # this pins Ruby-vs-SQL, so a value added to one copy and not the other is
  # caught rather than silently rejected at write time by the database.
  def test_migration_check_constraints_match_the_ruby_enum_mirrors
    sql = File.read(File.join(ROOT, "schema", "telemetry-ledger", "0004_event_type_retention.sql"))
    {
      "severity" => HARVESTER::EVENT_SEVERITIES,
      "kind" => HARVESTER::EVENT_KINDS,
      "reason" => HARVESTER::EVENT_REASONS
    }.each do |column, expected|
      clause = sql[/CHECK \(#{column} IN \(([^)]*)\)/m, 1]
      refute_nil clause, "0004 has no CHECK constraint for #{column}"
      assert_equal expected, clause.scan(/'([^']*)'/).flatten,
                   "0004's CHECK for #{column} disagrees with the harvester's Ruby mirror"
    end
    # category is deliberately unconstrained: it is free-form at write time.
    assert_nil sql[/CHECK \(category IN/], "category must stay free-form, not enum-checked"
  end

  # The harvester's control-character range and the CLI's terminal sanitizer are
  # a cross-file pair, and the comment on INGEST_CONTROL_CHARACTERS says to keep
  # them in agreement -- but "in agreement" means containment, not equality, and
  # until this test nothing enforced it. An earlier round of this change happened
  # precisely because the two had drifted apart on the C1 range.
  #
  # Compared by codepoint, not by regex source: either pattern may be respelled
  # harmlessly, and only the set of characters it matches is the contract.
  def test_ingest_control_characters_cover_the_cli_terminal_sanitizer
    load_agent_coord_cli
    hex = ->(codepoints) { codepoints.map { |codepoint| format("0x%02X", codepoint) } }

    # CONTROL_CODEPOINTS spans C0, DEL, and C1 -- every range either pattern
    # targets. Classified through the shared helper so this file keeps one
    # definition of the comparison window and one of "matches this pattern".
    control = codepoints_matching(HARVESTER::INGEST_CONTROL_CHARACTERS)
    terminal_unsafe = codepoints_matching(AgentCoord::LOG_CONTROL_CHARACTERS)

    # Containment: anything the CLI considers terminal-unsafe, the ledger must
    # strip too. This is the direction that matters -- the ledger is downstream.
    missing = terminal_unsafe - control
    assert_empty hex.call(missing),
                 "INGEST_CONTROL_CHARACTERS no longer covers every codepoint " \
                 "AgentCoord::LOG_CONTROL_CHARACTERS treats as control. Missing: " \
                 "#{hex.call(missing).join(', ')}. Widen the harvester pattern to match."

    # The intentional difference, pinned so a move in either direction reads as a
    # decision rather than an accident.
    ingest_only = control - terminal_unsafe
    assert_equal %w[0x09 0x0A 0x0D], hex.call(ingest_only),
                 "the harvester treats exactly tab/LF/CR as control beyond the CLI's set, because an " \
                 "ingested value is a single-line classifier or identifier while the CLI's log renderer " \
                 "handles those three separately. Changing this in either direction needs a deliberate " \
                 "call. Now: #{hex.call(ingest_only).join(', ')}"
  end

  # The structural pin that ends the laundering bug class. Three rounds of this
  # change found the same defect wearing different characters -- `strip` on NUL,
  # `[[:space:]]` on NEL -- because the trim runs before control detection, so
  # anything both trimmable and terminal-unsafe is silently removed.
  #
  # The fix is not another excluded character, it is a derived trim class: it is
  # exactly {space} plus the characters the CLI's own control definition
  # deliberately omits. Asserting that here means a future overlapping character
  # cannot reintroduce this bug without failing the suite.
  def test_trimmable_characters_never_overlap_the_cli_control_definition
    load_agent_coord_cli
    hex = ->(codepoints) { codepoints.map { |codepoint| format("0x%02X", codepoint) } }

    # Behavioural probe: a codepoint is trimmable if it is removed at the ends.
    # Shared with the other control pins via the helper rather than recomputed
    # here -- two copies of the trim class is the exact defect this file exists
    # to prevent, and one that drifted would leave this test asserting the old
    # semantics while still passing.
    terminal_unsafe = codepoints_matching(AgentCoord::LOG_CONTROL_CHARACTERS)
    trimmable = trimmable_codepoints

    # THE invariant: nothing the CLI considers terminal-unsafe may be trimmed.
    # NUL, NEL, VT, FF and the whole C1 range are all in LOG, so this single
    # assertion covers every past instance and any future one.
    laundered = trimmable & terminal_unsafe
    assert_empty hex.call(laundered),
                 "these codepoints are both trimmable and treated as control by " \
                 "AgentCoord::LOG_CONTROL_CHARACTERS, so they are silently removed before control " \
                 "detection and store identically to a value that never carried them: " \
                 "#{hex.call(laundered).join(', ')}. Remove them from INGEST_SURROUNDING_WHITESPACE."

    # And the trim class is derived, not chosen: space plus exactly the
    # characters INGEST treats as control but the CLI does not (tab, LF, CR).
    formatting_only = codepoints_matching(HARVESTER::INGEST_CONTROL_CHARACTERS) - terminal_unsafe
    assert_equal hex.call(([0x20] + formatting_only).sort), hex.call(trimmable),
                 "the trim class must be exactly {space} + (INGEST_CONTROL_CHARACTERS - " \
                 "LOG_CONTROL_CHARACTERS). Deriving it from the CLI is what keeps it disjoint " \
                 "from the terminal-unsafe set. Now: #{hex.call(trimmable).join(', ')}"
  end

  # The three-sanitizer agreement issue #171 asked for, stated precisely rather
  # than vacuously.
  #
  # After #171 there are not three control-character definitions left to compare.
  # `known` and `bounded_signal` share INGEST_CONTROL_CHARACTERS literally, so
  # asserting those two agree would compare a constant with itself and pass
  # forever. Reuse is the fix; a test restating it proves nothing.
  #
  # What reuse does NOT make automatic, and what this pins instead:
  #
  #   1. That `known`'s observable behaviour still tracks the shared constant --
  #      reintroducing a private literal, or a pre-trim that launders, fails here
  #      while leaving the constant untouched.
  #   2. That it tracks it at EVERY position in the string. Position is where the
  #      bug lived: `known` rejected NUL in the interior and trimmed it away at
  #      the ends, so an interior-only comparison would have called the old code
  #      correct.
  #   3. That both still contain AgentCoord::LOG_CONTROL_CHARACTERS, the CLI's
  #      own definition. This is the cross-file half, and it is the assertion
  #      that fails for both #171 defects at once.
  def test_known_control_range_agrees_with_the_shared_ingest_definition
    load_agent_coord_cli
    harvester = HARVESTER.allocate
    hex = ->(codepoints) { codepoints.map { |codepoint| format("0x%02X", codepoint) } }

    # CONTROL_CODEPOINTS spans C0, DEL, and C1 -- every range any of the three targets.
    control = codepoints_matching(HARVESTER::INGEST_CONTROL_CHARACTERS)
    terminal_unsafe = codepoints_matching(AgentCoord::LOG_CONTROL_CHARACTERS)
    trimmable = trimmable_codepoints
    interior = known_rejects_at(harvester, :interior)
    leading = known_rejects_at(harvester, :leading)
    trailing = known_rejects_at(harvester, :trailing)

    # 1. In the interior, `known` rejects exactly what the shared constant calls
    #    control -- no more, no less.
    assert_equal hex.call(control), hex.call(interior),
                 "known() no longer rejects exactly INGEST_CONTROL_CHARACTERS in the interior. It must " \
                 "reuse that constant rather than carry its own pattern. Now: #{hex.call(interior).join(', ')}"

    # 2. At the ends, the same set minus only what the trim class removes -- those
    #    are trimmed off and the remainder accepted, which is the intended
    #    normalization. Anything else being accepted at an end is laundering.
    at_ends = hex.call(control - trimmable)
    assert_equal at_ends, hex.call(leading),
                 "a control character was laundered at the start of the value: #{hex.call(leading).join(', ')}"
    assert_equal at_ends, hex.call(trailing),
                 "a control character was laundered at the end of the value: #{hex.call(trailing).join(', ')}"

    # 3. The cross-file containment, and the assertion that fails for both #171
    #    defects: C1 was absent from known()'s old range, and NUL/VT/FF were
    #    laundered at the ends by `String#strip`.
    escaping = terminal_unsafe.reject do |c|
      interior.include?(c) && leading.include?(c) && trailing.include?(c)
    end
    assert_empty hex.call(escaping),
                 "these codepoints are terminal-unsafe by AgentCoord::LOG_CONTROL_CHARACTERS but survive " \
                 "known() somewhere in the string, so a control-bearing value is accepted -- and, through " \
                 "enum(), promoted into a closed allowlist: #{hex.call(escaping).join(', ')}"

    # 4. The one intentional difference, pinned so a move reads as a decision:
    #    exactly tab/LF/CR are control in the interior yet trimmed at the ends.
    assert_equal %w[0x09 0x0A 0x0D], hex.call(interior - trailing),
                 "the only characters known() may treat differently by position are tab/LF/CR, which are " \
                 "layout noise at the ends and content corruption inside. Now: " \
                 "#{hex.call(interior - trailing).join(', ')}"
  end

  # The behaviour change #171 causes BEYOND the two defects it names. Called out
  # in its own test because it is real, and should be a decision on the record
  # rather than something discovered later in production.
  #
  # `String#strip` removes NUL, VT (U+000B), and FF (U+000C) as well as
  # whitespace, so `known("batch<VT>")` used to be accepted as "batch". The
  # derived trim class removes only tab, LF, CR, and space, so all three are now
  # rejected instead.
  #
  # Rejecting is right on the repo's own terms, not merely stricter. All three
  # are control characters by AgentCoord::LOG_CONTROL_CHARACTERS, and `known`
  # already rejected every one of them in the interior. Accepting them at the
  # ends was never a policy -- it was `strip` leaking its notion of whitespace
  # into a security boundary, and it left `known` disagreeing with itself about
  # the same character based only on where it sat in the string.
  def test_known_rejects_control_characters_at_the_ends_instead_of_trimming_them
    load_agent_coord_cli
    harvester = HARVESTER.allocate
    known = ->(value) { harvester.send(:known, value) }

    # Derived, not listed: exactly the codepoints `strip` removes that the trim
    # class does not. A future Ruby changing `strip` cannot leave this partial.
    # The trim half comes from the shared helper, so there is one definition of
    # "trimmable" in this file rather than one per test.
    stripped = CONTROL_CODEPOINTS.select { |codepoint| "x#{[codepoint].pack('U')}".strip == "x" }
    strip_only = stripped - trimmable_codepoints
    assert_equal %w[0x00 0x0B 0x0C], strip_only.map { |c| format("0x%02X", c) },
                 "the characters this change stops trimming are not the expected NUL/VT/FF"

    strip_only.each do |codepoint|
      char = [codepoint].pack("U")
      label = format("0x%02X", codepoint)
      # Each is terminal-unsafe by the CLI's own definition. That is what makes
      # rejecting them correct rather than arbitrary.
      assert_match AgentCoord::LOG_CONTROL_CHARACTERS, char,
                   "#{label} would not be worth rejecting if the CLI did not call it control"
      assert_nil known.call("batch#{char}"), "#{label} was trimmed off the end and the value accepted"
      assert_nil known.call("#{char}batch"), "#{label} was trimmed off the start and the value accepted"
      assert_nil known.call("ba#{char}tch"), "#{label} was accepted in the interior"
    end

    # Genuine whitespace still normalizes away, so no ordinary padded identifier
    # regresses. Codepoints written explicitly to keep the file greppable.
    tab = [0x0009].pack("U")
    lf = [0x000A].pack("U")
    cr = [0x000D].pack("U")
    assert_equal "batch-fixture", known.call("  batch-fixture#{lf}")
    assert_equal "batch-fixture", known.call("#{tab}batch-fixture#{cr}#{lf}")
  end

  # `category` is required for `error` events but bounded nowhere at write time,
  # so ingest must retain it rather than reject it. It previously went through
  # `known()`, which dropped an oversized or control-character category and took
  # the friction classifier with it.
  def test_oversized_and_dirty_category_is_retained_bounded_rather_than_dropped
    Dir.mktmpdir("agent-coordination-ledger-category") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      source = coordination_fixture
      [["long", "c" * 300], ["escape", "\u001Bbad-category"],
       ["unknown", "UNKNOWN"], ["ordinary", "test-failure"]].each_with_index do |(label, category), index|
        source["events"] << {
          "id" => "event-category-#{label}", "batch_id" => "batch-fixture",
          "repo" => "shakacode/agent-coordination", "target" => "78",
          "type" => "error", "severity" => "P1", "category" => category,
          "at" => "2026-07-18T02:0#{index}:00Z"
        }
      end
      File.write(source_path, JSON.generate(source))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr

      stored = sqlite_query(
        ledger_path,
        "SELECT COALESCE(category, 'NULL') FROM events WHERE event_type = 'error' ORDER BY event_ref"
      )
      # Exactly one NULL: the literal UNKNOWN. The other three are all retained.
      assert_equal 1, stored.count("NULL"),
                   "an error event lost its category at ingest: #{stored.inspect}"
      # The oversized category is retained, bounded, and marked as truncated.
      long = stored.find { |row| row.start_with?("c" * 32) }
      refute_nil long, "the oversized category was dropped instead of bounded"
      assert_operator long.bytesize, :<=, HARVESTER::SIGNAL_MAX_BYTES
      assert_match(/~[0-9a-f]{12}\z/, long)
      # Control characters never reach the column.
      assert_empty sqlite_query(
        ledger_path,
        "SELECT category FROM events WHERE category GLOB '*' || char(27) || '*'"
      )
      assert_includes stored, "test-failure"
      # The control character is stripped in place; the rest of the value stays.
      # (Unlike event_type_raw, a literal UNKNOWN category is "no value" -- that
      # is the single NULL asserted above.)
      assert(stored.any? { |row| row.start_with?("bad-category~") },
             "the control character was not stripped in place: #{stored.inspect}")
    end
  end

  # A clean value can be constructed to equal some other value's sanitized form,
  # and without reserving the marker shape both would store identically --
  # collapsing two distinct friction clusters into one. The sanitized shape is
  # therefore reserved: an input already wearing it is never returned unchanged.
  def test_a_clean_value_cannot_impersonate_another_values_sanitized_form
    harvester = HARVESTER.allocate
    dirty = "ci#{[0x001B].pack('U')}-timeout"
    sanitized = harvester.send(:bounded_signal, dirty, unknown_is_value: false)

    assert_equal "ci-timeout", sanitized.sub(HARVESTER::SIGNAL_SANITIZED_SHAPE, "")
    assert_match HARVESTER::SIGNAL_SANITIZED_SHAPE, sanitized

    # An operator supplying that exact literal must not land on the same row.
    impersonation = harvester.send(:bounded_signal, sanitized.dup, unknown_is_value: false)
    refute_equal sanitized, impersonation,
                 "a clean value impersonated another value's sanitized form: #{sanitized.inspect}"
    assert impersonation.start_with?("#{sanitized}~"),
           "the reserved shape must route through the sanitizer: #{impersonation.inspect}"

    # Any value wearing the shape is marked, even with nothing else wrong.
    shaped = "release~0123456789ab"
    refute_equal shaped, harvester.send(:bounded_signal, shaped, unknown_is_value: true)
    # ...while a near-miss (wrong length, non-hex, marker not at the end) is not.
    ["release~0123456789a", "release~0123456789az", "release~0123456789ab-x"].each do |near_miss|
      assert_equal near_miss, harvester.send(:bounded_signal, near_miss, unknown_is_value: true),
                   "a value that only resembles the shape must be left alone: #{near_miss.inspect}"
    end
  end

  # The reserved shape is derived from the marker and digest-length constants, so
  # it must keep matching what the sanitizer actually emits if either changes.
  def test_sanitized_shape_matches_what_the_sanitizer_emits
    harvester = HARVESTER.allocate
    emitted = harvester.send(:bounded_signal, "x" * (HARVESTER::SIGNAL_MAX_BYTES + 1), unknown_is_value: true)

    assert_match HARVESTER::SIGNAL_SANITIZED_SHAPE, emitted,
                 "SIGNAL_SANITIZED_SHAPE no longer matches sanitizer output: #{emitted.inspect}"
    suffix = emitted[HARVESTER::SIGNAL_SANITIZED_SHAPE]
    assert_equal HARVESTER::SIGNAL_TRUNCATION_MARKER, suffix[0]
    assert_equal HARVESTER::SIGNAL_DIGEST_LENGTH, suffix.length - 1
    # Reserving the shape is what makes the two paths' outputs disjoint.
    refute_match HARVESTER::SIGNAL_SANITIZED_SHAPE,
                 harvester.send(:bounded_signal, "ordinary-value", unknown_is_value: true)
  end

  # The laundering class, not one instance of it. The trim runs before control
  # detection, so any character that is both trimmable and control is silently
  # removed and the value stores identically to one that never carried it --
  # no digest, no drift row. `String#strip` overlapped on NUL; `[[:space:]]`
  # overlapped on NEL. Each of these must take the control path instead.
  def test_control_characters_are_never_laundered_by_the_trim
    harvester = HARVESTER.allocate
    clean = harvester.send(:bounded_signal, "operator-type", unknown_is_value: true)
    assert_equal "operator-type", clean

    {
      "NUL" => 0x0000, "VT" => 0x000B, "FF" => 0x000C,
      "NEL" => 0x0085, "CSI" => 0x009B
    }.each do |name, codepoint|
      character = [codepoint].pack("U")
      assert_match HARVESTER::INGEST_CONTROL_CHARACTERS, character, "#{name} must count as control"

      suffixed = harvester.send(:bounded_signal, "operator-type#{character}", unknown_is_value: true)
      refute_equal clean, suffixed, "a #{name}-suffixed type was laundered into its clean twin"
      assert suffixed.start_with?("operator-type~"),
             "#{name} must be stripped in place and digest-marked: #{suffixed.inspect}"

      category = harvester.send(:bounded_signal, "cat#{character}", unknown_is_value: false)
      refute_equal "cat", category, "a #{name}-suffixed category was silently cleaned"
      assert category.start_with?("cat~"), "#{name} category: #{category.inspect}"

      # A value that is nothing but control characters carried something, so it
      # stores as a bare digest rather than NULL.
      only = harvester.send(:bounded_signal, character, unknown_is_value: true)
      assert_match(/\A~[0-9a-f]{12}\z/, only, "a #{name}-only value must not vanish")
    end

    # Genuine trimmable whitespace still normalizes away entirely...
    assert_nil harvester.send(:bounded_signal, "   ", unknown_is_value: true)
    assert_nil harvester.send(:bounded_signal, "\t\r\n ", unknown_is_value: true)
    # ...and the T3 decision is unchanged: surrounding tab/LF/CR/space collapse.
    assert_equal clean, harvester.send(:bounded_signal, "  operator-type\n", unknown_is_value: true)
    assert_equal clean, harvester.send(:bounded_signal, "\toperator-type\r\n", unknown_is_value: true)
    # But the same characters in the interior are corruption, not layout, so
    # they are stripped and marked rather than kept.
    interior = harvester.send(:bounded_signal, "operator\ttype", unknown_is_value: true)
    assert_equal "operatortype~#{interior[/~(.+)\z/, 1]}", interior
    refute_equal "operator\ttype", interior
  end

  # End to end: a control-bearing type must not be stored identically to its
  # clean twin, which would merge distinct raw types into one drift row. Covers
  # both characters that previously laundered -- NUL via `strip`, NEL via
  # `[[:space:]]` -- so the ingest path is pinned, not just the sanitizer.
  def test_control_bearing_values_do_not_collide_with_their_clean_twins_at_ingest
    Dir.mktmpdir("agent-coordination-ledger-control") do |dir| # rubocop:disable Metrics/BlockLength
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      nul = [0x0000].pack("U")
      nel = [0x0085].pack("U")
      source = coordination_fixture
      pairs = { "clean" => "operator-type", "nul" => "operator-type#{nul}",
                "nel" => "operator-type#{nel}" }
      pairs.each_with_index do |(label, type), index|
        source["events"] << {
          "id" => "event-nul-#{label}", "batch_id" => "batch-fixture",
          "repo" => "shakacode/agent-coordination", "target" => "78",
          "type" => type, "at" => "2026-07-18T04:0#{index}:00Z"
        }
      end
      File.write(source_path, JSON.generate(source))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr

      raws = sqlite_query(ledger_path, "SELECT event_type_raw FROM events ORDER BY event_type_raw")
      assert_equal raws.uniq.length, raws.length, "a NUL-bearing type collided with its clean twin: #{raws}"
      assert_includes raws, "operator-type"
      assert(raws.any? { |row| row.start_with?("operator-type~") },
             "the NUL-suffixed type was not digest-marked: #{raws.inspect}")
      raws.each do |row|
        refute_includes row.codepoints, 0x0000, "a NUL survived ingest"
        refute_includes row.codepoints, 0x0085, "a NEL survived ingest"
      end
      assert_equal 3, raws.length, "expected one row per distinct type: #{raws.inspect}"
    end
  end

  # C1 controls (U+0080-U+009F) are as dangerous in a terminal as C0: U+009B is
  # CSI, which opens an escape sequence on its own. The sanitizer originally
  # covered only C0 and DEL, so a C1 character passed through into the ledger and
  # defeated the terminal-safety guarantee the sanitizer exists to provide. The
  # codepoint is written explicitly so this file stays readable and greppable.
  def test_c1_control_characters_are_stripped_like_c0
    csi = [0x009B].pack("U")
    harvester = HARVESTER.allocate

    assert_match HARVESTER::INGEST_CONTROL_CHARACTERS, csi,
                 "C1 controls must be recognized as control characters"
    # Detection and stripping must agree: a value that is nothing but a C1 char
    # takes the sanitized path rather than being returned verbatim.
    c1_only = harvester.send(:bounded_signal, csi, unknown_is_value: true)
    refute_equal csi, c1_only, "a C1-only value was returned verbatim"
    assert_match(/\A~[0-9a-f]{12}\z/, c1_only)

    stored = harvester.send(:bounded_signal, "bad#{csi}cat", unknown_is_value: false)
    refute_includes stored.codepoints, 0x009B, "a C1 control survived sanitizing"
    assert stored.start_with?("badcat~"), "the C1 char must be stripped in place: #{stored.inspect}"
    # The digest is taken over the original, so two values differing only in
    # their stripped controls stay distinct.
    other = harvester.send(:bounded_signal, "badcat#{csi}", unknown_is_value: false)
    refute_equal stored, other, "stripping collapsed two distinct originals"
  end

  # End to end: a C1 control in a category must not reach the ledger.
  def test_c1_control_does_not_survive_ingest
    Dir.mktmpdir("agent-coordination-ledger-c1") do |dir|
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      source = coordination_fixture
      source["events"] << {
        "id" => "event-c1", "batch_id" => "batch-fixture",
        "repo" => "shakacode/agent-coordination", "target" => "78",
        "type" => "error", "severity" => "P1",
        "category" => "bad#{[0x009B].pack('U')}cat", "at" => "2026-07-18T03:00:00Z"
      }
      File.write(source_path, JSON.generate(source))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr

      stored = sqlite_query(ledger_path, "SELECT category FROM events WHERE category IS NOT NULL")
      refute_empty stored, "the category was dropped instead of sanitized"
      stored.each do |row|
        refute_includes row.codepoints, 0x009B, "a C1 control survived ingest"
        refute_match HARVESTER::INGEST_CONTROL_CHARACTERS, row
      end
    end
  end

  # The closed enums need no sanitizing: `enum` nils anything outside the set
  # whatever its length, and no member of any set is a value `known()` drops.
  # Pinned so a future member that would be dropped is caught.
  def test_closed_enum_members_are_never_dropped_by_known
    harvester = HARVESTER.allocate
    {
      "EVENT_SEVERITIES" => HARVESTER::EVENT_SEVERITIES,
      "EVENT_KINDS" => HARVESTER::EVENT_KINDS,
      "EVENT_REASONS" => HARVESTER::EVENT_REASONS
    }.each do |name, values|
      dropped = values.reject { |value| harvester.send(:known, value) == value }
      assert_empty dropped, "#{name} contains values that ingest would drop: #{dropped.inspect}"
    end
  end

  # Surrounding whitespace is normalized away before storage, deliberately: two
  # values differing only there are the same value, and emitting two drift rows
  # for them would be worse output. Pinned so it reads as intended rather than
  # accidental. A CLI-written type cannot contain whitespace anyway --
  # `validate_segment!` restricts `--type` to `[A-Za-z0-9_:-]` and dots.
  def test_surrounding_whitespace_is_normalized_not_treated_as_a_distinct_value
    harvester = HARVESTER.allocate
    plain = harvester.send(:bounded_signal, "operator-adhoc-type", unknown_is_value: true)
    padded = harvester.send(:bounded_signal, "  operator-adhoc-type\n", unknown_is_value: true)

    assert_equal "operator-adhoc-type", plain
    assert_equal plain, padded, "surrounding whitespace must normalize, not fork into a second value"
    refute_match(/~/, padded, "normalization alone must not mark the value as truncated")
    # The CLI cannot produce such a type in the first place.
    refute_match(/\A[A-Za-z0-9_:-]+(?:\.[A-Za-z0-9_:-]+)*\z/, "  operator-adhoc-type\n")
  end

  # The clamped column and the raw column cannot disagree: sanitizing can never
  # hide an event the allowlist would have classified, because every allowlisted
  # type is short and clean. Checked, not assumed.
  def test_no_allowlisted_event_type_ever_requires_sanitizing
    harvester = HARVESTER.allocate
    needing = HARVESTER::EVENT_TYPES.reject do |type|
      harvester.send(:bounded_signal, type, unknown_is_value: true) == type
    end
    assert_empty needing,
                 "these allowlisted types would be altered by event_type_raw sanitizing: #{needing.inspect}"
    HARVESTER::EVENT_TYPES.each do |type|
      assert_operator type.bytesize, :<=, HARVESTER::SIGNAL_MAX_BYTES
      refute_match HARVESTER::INGEST_CONTROL_CHARACTERS, type
    end
  end

  # An event type outside the allowlist must stay countable rather than becoming
  # an invisible NULL, which is the failure mode #112 was reported for.
  def test_unrecognized_event_type_is_visible_as_drift_rather_than_a_silent_null
    Dir.mktmpdir("agent-coordination-ledger-event-drift") do |dir|
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      source = coordination_fixture
      source["events"] << {
        "id" => "event-drift-fixture", "batch_id" => "batch-fixture",
        "repo" => "shakacode/agent-coordination", "target" => "78",
        "type" => "not-a-known-event-type", "at" => "2026-07-18T01:30:00Z"
      }
      File.write(source_path, JSON.generate(source))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr

      assert_equal ["NULL|not-a-known-event-type"], sqlite_query(
        ledger_path, "SELECT COALESCE(event_type, 'NULL'), event_type_raw FROM events"
      )
      assert_equal ["batch-fixture|not-a-known-event-type|1"],
                   sqlite_query(ledger_path, "SELECT * FROM event_type_drift")
    end
  end

  # The residual PR #155 documented and deliberately left open, proven closed.
  #
  # A NUL-suffixed allowlisted type used to be promoted by `known` -- `strip`
  # removed the NUL, then "error" matched the allowlist -- while `bounded_signal`
  # digest-marked the very same input. The row landed visibly inconsistent:
  #
  #   event_type     = "error"
  #   event_type_raw = "error~6e7af28ae2a0"
  #
  # and `event_type_drift` did not count it, because that view keys on
  # `event_type IS NULL` and this row's `event_type` was not NULL. So the one
  # view whose job is to surface unrecognized types stayed silent about a
  # control-bearing one.
  #
  # Asserted end to end -- real CLI, real ledger, query against the view -- rather
  # than as a unit assertion on `known`, because the claim being made is about
  # what an operator can actually see in the ledger.
  def test_nul_suffixed_allowlisted_type_is_counted_by_the_drift_view
    Dir.mktmpdir("agent-coordination-ledger-nul-promotion") do |dir|
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      nul = [0x0000].pack("U")
      source = coordination_fixture
      source["events"] << {
        "id" => "event-nul-promotion", "batch_id" => "batch-fixture",
        "repo" => "shakacode/agent-coordination", "target" => "78",
        "type" => "error#{nul}", "severity" => "P1", "category" => "test-failure",
        "at" => "2026-07-18T04:00:00Z"
      }
      File.write(source_path, JSON.generate(source))

      _stdout, stderr, status = Open3.capture3(
        CLI, "harvest", "--ledger", ledger_path,
        "--coordination-json", source_path, "--batch-id", "batch-fixture"
      )
      assert status.success?, stderr

      # No longer promoted: the allowlist never sees a trimmed "error".
      assert_equal ["NULL"],
                   sqlite_query(ledger_path, "SELECT COALESCE(event_type, 'NULL') FROM events")
      # The raw column still records that something was there, digest-marked, so
      # the drift row carries the evidence rather than just a NULL.
      raw = sqlite_query(ledger_path, "SELECT event_type_raw FROM events")
      assert_equal 1, raw.length, "expected exactly one event row: #{raw.inspect}"
      assert raw.first.start_with?("error~"),
             "the raw type lost its digest marker: #{raw.inspect}"

      # The whole point: the row is now COUNTED by the view that used to miss it.
      assert_equal ["batch-fixture|#{raw.first}|1"],
                   sqlite_query(ledger_path, "SELECT * FROM event_type_drift")
    end
  end

  private

  def invalid_utf8_documents
    {
      "value" => lambda do
        source = coordination_fixture
        source.fetch("events") << {
          "id" => "event-invalid-utf8", "batch_id" => "batch-fixture",
          "repo" => "shakacode/agent-coordination", "target" => "PLACEHOLDER",
          "type" => "error", "severity" => "P1", "category" => "test-failure",
          "at" => "2026-07-18T05:00:00Z"
        }
        JSON.generate(source).b.sub("PLACEHOLDER".b, "78\xFF".b)
      end,
      "key" => lambda do
        source = coordination_fixture
        source["PLACEHOLDER"] = "ignored"
        JSON.generate(source).b.sub("PLACEHOLDER".b, "invalid\xFFkey".b)
      end
    }
  end

  def parse_codex_host_session(cwd:, model:, effort:, pricing_profile:)
    records = [
      {
        "type" => "session_meta",
        "payload" => { "id" => "control-test", "cwd" => cwd, "pricing_profile" => pricing_profile }
      },
      {
        "type" => "turn_context",
        "payload" => { "model" => model, "effort" => effort, "pricing_profile" => pricing_profile }
      },
      {
        "type" => "event_msg",
        "payload" => {
          "type" => "token_count",
          "info" => { "last_token_usage" => { "input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2 } }
        }
      }
    ]
    HOST_ADAPTERS::Parser.new("codex").parse(
      records.map { |record| JSON.generate(record) }.join("\n"), "codex:control-test"
    )
  end

  # bin/agent-coord guards execution with a $PROGRAM_NAME check and keeps the
  # event vocabulary in module-level constants, so loading it here is side-effect
  # free and gives the test the CLI's own definitions rather than a copy.
  def load_agent_coord_cli
    load COORD_CLI unless defined?(AgentCoord::TYPED_EVENT_ALLOWED_FIELDS)
  end

  # Which of CONTROL_CODEPOINTS `pattern` treats as control. Compared by
  # codepoint rather than by regex source, because either pattern may be
  # respelled harmlessly and only the set of characters it matches is the
  # contract.
  def codepoints_matching(pattern)
    CONTROL_CODEPOINTS.select { |codepoint| [codepoint].pack("U").match?(pattern) }
  end

  # Which of CONTROL_CODEPOINTS the ingest trim class removes from the ends of a
  # value. Probed behaviourally rather than read off the pattern.
  def trimmable_codepoints
    CONTROL_CODEPOINTS.select do |codepoint|
      "x#{[codepoint].pack('U')}".gsub(HARVESTER::INGEST_SURROUNDING_WHITESPACE, "") == "x"
    end
  end

  # Which of CONTROL_CODEPOINTS `known` rejects when the character sits at
  # `position` within an otherwise clean value.
  #
  # Position is probed separately because that is exactly where the #171
  # laundering bug lived: `known` rejected NUL in the interior of a value and
  # trimmed it away at the ends, so a check that only looked at the interior
  # would have called the old code correct.
  def known_rejects_at(harvester, position)
    CONTROL_CODEPOINTS.select do |codepoint|
      character = [codepoint].pack("U")
      value = case position
              when :leading then "#{character}abcd"
              when :interior then "ab#{character}cd"
              when :trailing then "abcd#{character}"
              else raise ArgumentError, "unknown position #{position.inspect}"
              end
      harvester.send(:known, value).nil?
    end
  end

  # Every event type bin/agent-coord writes, derived from the CLI two
  # independent ways because neither alone is sufficient:
  #
  #   1. Constants -- TYPED_EVENT_ALLOWED_FIELDS declares the operator-supplied
  #      typed signals, and that is authoritative for them.
  #   2. Literal `type:` emission sites -- the four types the CLI emits itself
  #      are bare string literals at their call sites. Their appearance in
  #      BATCH_AUDIT_ORDINARY_LIFECYCLE_TYPES is incidental bookkeeping for the
  #      unrelated batch-audit feature, NOT a declaration of what is emitted, so
  #      a new hardcoded emission would touch no constant and a constants-only
  #      derivation would never see it. Scanning the source closes that hole.
  #
  # Keep both. Dropping either one silently narrows what this guard can catch.
  def cli_emitted_event_types
    load_agent_coord_cli
    (AgentCoord::BATCH_AUDIT_ORDINARY_LIFECYCLE_TYPES +
      AgentCoord::TYPED_EVENT_ALLOWED_FIELDS.keys +
      cli_literal_emission_types +
      [cli_terminal_event_type]).uniq.sort
  end

  # The `type:` literals the CLI passes to its own event writers. Matches the
  # four self-emitted types today; a fifth added the same way is caught here.
  def cli_literal_emission_types
    types = File.read(COORD_CLI).scan(/^\s+type: "([^"]+)"/).flatten.uniq
    refute_empty types,
                 "no literal `type:` emission sites found in bin/agent-coord -- the scan pattern has " \
                 "gone stale and this guard is no longer checking hardcoded emissions"
    types
  end

  # The terminal closeout type has no CLI constant -- it is the literal that
  # `terminal_event?` compares against -- so read it from the source instead of
  # restating it. Renaming it there fails this derivation loudly rather than
  # silently shrinking the set this contract is checked against.
  def cli_terminal_event_type
    source = File.read(COORD_CLI)
    type = source[/def terminal_event\?\(options\)\s*\n\s*options\[:type\] == "([^"]+)"/, 1]
    refute_nil type, "could not derive the terminal event type from bin/agent-coord"
    type
  end

  # Drives the real CLI against a temp state root so it writes one event of every
  # type it emits, then captures `status --json` as the harvester's coordination
  # source. claim.acquired, claim.released, and phase.changed are never recorded
  # directly: they are emitted as side effects of claim, release, and a heartbeat
  # that moves an already-set phase, so the corpus has to drive those commands.
  def record_cli_event_corpus(dir)
    state = File.join(dir, "state")
    env = CORPUS_ENV.merge("XDG_CONFIG_HOME" => File.join(dir, "config"))
    FileUtils.mkdir_p(env.fetch("XDG_CONFIG_HOME"))
    manifest = File.join(dir, "manifest.json")
    File.write(manifest, JSON.generate(
                           "batch_id" => CORPUS_BATCH, "repo" => CORPUS_REPO,
                           "lanes" => [{ "name" => "maker", "owner" => "corpus-worker",
                                         "targets" => [CORPUS_TARGET] }]
                         ))
    run_coord(env, "register-batch", "--state-root", state, "--file", manifest)
    corpus_commands(state).each { |args| run_coord(env, *args) }

    source_path = File.join(dir, "coordination.json")
    status_json = run_coord(env, "status", "--state-root", state, "--json")
    File.write(source_path, status_json)
    [JSON.parse(status_json).fetch("events").map { |event| event.fetch("type") }.sort, source_path]
  end

  def corpus_commands(state)
    common = ["--state-root", state, "--batch-id", CORPUS_BATCH,
              "--repo", CORPUS_REPO, "--target", CORPUS_TARGET, "--agent-id", "corpus-worker"]
    lane = ["--lane", "maker"]
    [
      # claim.acquired
      ["claim", *common, *lane, "--host", "claude-code"],
      # the first phase is captured by claim.acquired; the second one transitions
      # and is what emits phase.changed
      ["heartbeat", *common, "--phase", "implementing", "--host", "claude-code"],
      ["heartbeat", *common, "--phase", "verifying", "--host", "claude-code"],
      ["record-event", *common, *lane, "--type", "help_requested", "--reason", "question"],
      ["record-event", *common, *lane, "--type", "escalation_requested",
       "--from-route", "sonnet/medium", "--to-route", "opus/high", "--evidence", "two failed attempts"],
      ["record-event", *common, *lane, "--type", "error",
       "--severity", "P1", "--category", "harvest-corpus", "--message", "corpus error signal"],
      ["record-event", *common, *lane, "--type", "human_intervention", "--kind", "takeover"],
      # claim.released
      ["release", *common, *lane],
      ["record-event", *common, *lane, "--type", "lane_closed", "--terminal", "done",
       "--branch", "claude/event-corpus", "--pr-state", "merged", "--host", "claude-code",
       "--pr-url", "https://github.com/shakacode/agent-coordination/pull/1",
       "--evidence-url", "https://github.com/shakacode/agent-coordination/pull/1"]
    ]
  end

  # A ledger built from every migration except the last one, holding an event
  # row written before the event-retention columns existed.
  def seed_ledger_without_event_retention(dir, ledger_path)
    older = File.join(dir, "migrations")
    FileUtils.mkdir_p(older)
    migrations = Dir.glob(File.join(ROOT, "schema", "telemetry-ledger", "*.sql"))
    assert_equal "0004_event_type_retention.sql", File.basename(migrations.last)
    migrations[0..-2].each { |path| FileUtils.cp(path, older) }

    ledger = AgentCoord::Telemetry::Ledger.new(ledger_path, migrations_path: older)
    ledger.execute(
      "INSERT INTO source_artifacts (source_key, source_kind, source_ref, source_sha256) VALUES (?, ?, ?, ?)",
      ["coordination:pre", "coordination", "coordination:pre", "a" * 64]
    )
    ledger.execute(
      "INSERT INTO events (event_ref, event_type, join_status, source_artifact_id, source_record_sha256) " \
      "VALUES (?, ?, ?, ?, ?)",
      ["pre-existing", "lane_closed", "exact", 1, "b" * 64]
    )
  end

  # Every input `known()` rejects outright, plus the genuinely-absent cases, as
  # [label, type] pairs. `:absent` means the event carries no "type" key at all.
  # The control characters are written as escapes so this file holds no raw
  # control bytes.
  def unsanitizable_event_types
    [
      ["long", "x" * 300],
      ["long-sibling", "#{'x' * 299}y"],
      ["unknown-literal", "UNKNOWN"],
      ["escape", "\u001B[31mred"],
      ["control-only", "\u0001\u0002"],
      ["ordinary", "operator-adhoc-type"],
      ["blank", "   "],
      ["absent", :absent]
    ]
  end

  def run_coord(env, *args)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, COORD_CLI, *args)
    assert status.success?, "agent-coord #{args.first} failed:\n#{stdout}\n#{stderr}"
    stdout
  end

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
