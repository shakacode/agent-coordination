# frozen_string_literal: true

require "digest"
require "sqlite3"

module AgentCoord
  module Telemetry
    class Ledger
      class MigrationError < StandardError; end

      MIGRATIONS = File.expand_path("../../schema/telemetry-ledger", __dir__)

      def initialize(path, migrations_path: MIGRATIONS)
        @database = SQLite3::Database.new(path)
        @database.results_as_hash = true
        @database.execute("PRAGMA foreign_keys = ON")
        @migrations_path = migrations_path
        migrate!
      end

      def transaction(&)
        @database.transaction(&)
      end

      def execute(sql, parameters = [])
        @database.execute(sql, parameters)
      end

      def rows(sql, parameters = [])
        execute(sql, parameters)
      end

      def first(sql, parameters = [])
        @database.get_first_row(sql, parameters)
      end

      def upsert_source_artifact(row)
        execute(
          <<~SQL,
            INSERT INTO source_artifacts (source_key, source_kind, source_ref, source_sha256)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
              source_kind = excluded.source_kind,
              source_ref = excluded.source_ref,
              source_sha256 = excluded.source_sha256
          SQL
          row.values_at("source_key", "source_kind", "source_ref", "source_sha256")
        )
        first("SELECT id FROM source_artifacts WHERE source_key = ?", [row.fetch("source_key")]).fetch("id")
      end

      def delete_batch(batch_id)
        execute("DELETE FROM batches WHERE batch_id = ?", [batch_id])
      end

      def insert_batch(row)
        execute(
          <<~SQL,
            INSERT INTO batches (
              batch_id, repo, join_status, status, registered_at, updated_at,
              synthetic, source_kind, source_artifact_id, source_record_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          row.values_at(
            "batch_id", "repo", "join_status", "status", "registered_at", "updated_at",
            "synthetic", "source_kind", "source_artifact_id", "source_record_sha256"
          )
        )
      end

      def upsert_lane(row)
        execute(
          <<~SQL,
            INSERT INTO lanes (
              batch_id, lane_id, owner_ref, status, host_family, session_ref, source_record_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(batch_id, lane_id) DO UPDATE SET
              owner_ref = excluded.owner_ref,
              status = excluded.status,
              host_family = excluded.host_family,
              session_ref = excluded.session_ref,
              source_record_sha256 = excluded.source_record_sha256
          SQL
          row.values_at(
            "batch_id", "lane_id", "owner_ref", "status", "host_family", "session_ref", "source_record_sha256"
          )
        )
      end

      def insert_target_observation(row)
        execute(
          <<~SQL,
            INSERT INTO target_observations (
              batch_id, lane_id, repo, target, status, pr_url, join_status, source_record_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          row.values_at(
            "batch_id", "lane_id", "repo", "target", "status", "pr_url", "join_status", "source_record_sha256"
          )
        )
      end

      def insert_target_unit(row)
        execute(
          <<~SQL,
            INSERT INTO target_units (
              batch_id, repo, target, join_status, outcome, outcome_evidence_status, pr_join_status
            ) VALUES (?, ?, ?, 'exact', NULL, 'unknown', ?)
          SQL
          row.values_at("batch_id", "repo", "target", "pr_join_status")
        )
        first(
          "SELECT id FROM target_units WHERE batch_id = ? AND repo = ? AND target = ?",
          row.values_at("batch_id", "repo", "target")
        ).fetch("id")
      end

      def insert_lane_membership(target_unit_id, lane_id)
        execute(
          "INSERT OR IGNORE INTO lane_memberships (target_unit_id, lane_id) VALUES (?, ?)",
          [target_unit_id, lane_id]
        )
      end

      def delete_github_prs(source_artifact_id)
        execute("DELETE FROM github_prs WHERE source_artifact_id = ?", [source_artifact_id])
      end

      def insert_github_pr(row)
        execute(
          <<~SQL,
            INSERT INTO github_prs (
              repo, number, url, state, created_at, merged_at, source_artifact_id, source_record_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(repo, number) DO UPDATE SET
              url = excluded.url,
              state = excluded.state,
              created_at = excluded.created_at,
              merged_at = excluded.merged_at,
              source_artifact_id = excluded.source_artifact_id,
              source_record_sha256 = excluded.source_record_sha256
          SQL
          row.values_at(
            "repo", "number", "url", "state", "created_at", "merged_at",
            "source_artifact_id", "source_record_sha256"
          )
        )
        first("SELECT id FROM github_prs WHERE repo = ? AND number = ?", row.values_at("repo", "number")).fetch("id")
      end

      private

      def migrate!
        paths = migration_paths
        verify_applied_versions_present!(paths)
        paths.each do |path|
          version = File.basename(path, ".sql")
          sql = File.read(path, encoding: "UTF-8")
          digest = Digest::SHA256.hexdigest(sql)
          applied_digest = applied_migration_digest(version)
          if applied_digest
            raise MigrationError, "applied migration hash mismatch" unless applied_digest == digest

            next
          end

          @database.transaction do
            @database.execute_batch(sql)
            @database.execute(
              "INSERT INTO schema_migrations (version, source_sha256) VALUES (?, ?)",
              [version, digest]
            )
          end
        end
      end

      def migration_paths
        Dir.glob(File.join(@migrations_path, "*.sql"), sort: true)
      end

      def verify_applied_versions_present!(paths)
        return unless @database.table_info("schema_migrations").any?

        available = paths.map { |path| File.basename(path, ".sql") }
        applied = @database.execute("SELECT version FROM schema_migrations").map { |row| row.fetch("version") }
        raise MigrationError, "applied migration source missing" unless (applied - available).empty?
      end

      def applied_migration_digest(version)
        return unless @database.table_info("schema_migrations").any?

        @database.get_first_value("SELECT source_sha256 FROM schema_migrations WHERE version = ?", version)
      end
    end
  end
end
