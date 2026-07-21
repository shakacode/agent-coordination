# frozen_string_literal: true

require "digest"
require "sqlite3"

module AgentCoord
  module Telemetry
    class Ledger
      MIGRATIONS = File.expand_path("../../schema/telemetry-ledger", __dir__)

      def initialize(path)
        @database = SQLite3::Database.new(path)
        @database.execute("PRAGMA foreign_keys = ON")
        migrate!
      end

      def transaction(&)
        @database.transaction(&)
      end

      def upsert_batch(row)
        @database.execute(
          <<~SQL,
            INSERT INTO batches (
              batch_id, repo, status, registered_at, updated_at, synthetic,
              source_kind, source_ref, source_record_id, source_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(batch_id) DO UPDATE SET
              repo = excluded.repo,
              status = excluded.status,
              registered_at = excluded.registered_at,
              updated_at = excluded.updated_at,
              synthetic = excluded.synthetic,
              source_kind = excluded.source_kind,
              source_ref = excluded.source_ref,
              source_record_id = excluded.source_record_id,
              source_sha256 = excluded.source_sha256
          SQL
          row.values_at(
            "batch_id", "repo", "status", "registered_at", "updated_at", "synthetic",
            "source_kind", "source_ref", "source_record_id", "source_sha256"
          )
        )
      end

      def upsert_target(row)
        @database.execute(
          <<~SQL,
            INSERT INTO target_units (
              batch_id, repo, target, lane_count, lanes_json, outcome,
              source_kind, source_ref, source_record_id, source_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(batch_id, repo, target) DO UPDATE SET
              lane_count = excluded.lane_count,
              lanes_json = excluded.lanes_json,
              outcome = excluded.outcome,
              source_kind = excluded.source_kind,
              source_ref = excluded.source_ref,
              source_record_id = excluded.source_record_id,
              source_sha256 = excluded.source_sha256
          SQL
          row.values_at(
            "batch_id", "repo", "target", "lane_count", "lanes_json", "outcome",
            "source_kind", "source_ref", "source_record_id", "source_sha256"
          )
        )
      end

      private

      def migrate!
        migration_paths.each do |path|
          version = File.basename(path, ".sql")
          next if migration_applied?(version)

          sql = File.read(path, encoding: "UTF-8")
          @database.transaction do
            @database.execute_batch(sql)
            @database.execute(
              "INSERT INTO schema_migrations (version, source_sha256) VALUES (?, ?)",
              [version, Digest::SHA256.hexdigest(sql)]
            )
          end
        end
      end

      def migration_paths
        Dir.glob(File.join(MIGRATIONS, "*.sql")).sort
      end

      def migration_applied?(version)
        return false unless @database.table_info("schema_migrations").any?

        @database.get_first_value("SELECT 1 FROM schema_migrations WHERE version = ?", version) == 1
      end
    end
  end
end
