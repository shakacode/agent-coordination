# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class TelemetryHarvesterTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CLI = File.join(ROOT, "bin", "agent-coord-harvest")

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

  def test_date_range_harvest_is_inclusive_and_idempotent
    Dir.mktmpdir("agent-coordination-ledger-range") do |dir|
      source_path = File.join(dir, "coordination.json")
      ledger_path = File.join(dir, "telemetry.sqlite3")
      source = coordination_fixture
      source.fetch("batches") << coordination_fixture.fetch("batches").first.merge(
        "batch_id" => "batch-outside",
        "registered_at" => "2026-07-16T23:59:59Z",
        "updated_at" => "2026-07-16T23:59:59Z"
      )
      File.write(source_path, JSON.generate(source))

      2.times do
        stdout, stderr, status = Open3.capture3(
          CLI, "harvest", "--ledger", ledger_path,
          "--coordination-json", source_path,
          "--from", "2026-07-18", "--to", "2026-07-18"
        )
        assert status.success?, "harvest failed:\n#{stdout}\n#{stderr}"
        assert_equal "harvested batches=1 targets=1 usage=0\n", stdout
        assert_empty stderr
      end

      assert_equal ["batch-fixture"], sqlite_query(ledger_path, "SELECT batch_id FROM batches ORDER BY batch_id")
      assert_equal ["1"], sqlite_query(ledger_path, "SELECT COUNT(*) FROM target_units")
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
