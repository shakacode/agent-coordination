# frozen_string_literal: true

module AgentCoord
  module Telemetry
    class Scorecards
      def initialize(ledger)
        @ledger = ledger
      end

      def batch(batch_id)
        batch = @ledger.first("SELECT batch_id FROM batches WHERE batch_id = ?", [batch_id])
        return unless batch

        outcomes = @ledger.rows(
          "SELECT outcome, target_units FROM outcome_scorecard WHERE batch_id = ? ORDER BY outcome",
          [batch_id]
        ).to_h { |row| [row.fetch("outcome"), row.fetch("target_units")] }
        costs = @ledger.first("SELECT * FROM cost_scorecard WHERE batch_id = ?", [batch_id])
        reviews = @ledger.first("SELECT * FROM review_economics_scorecard WHERE batch_id = ?", [batch_id])
        {
          "batch_id" => batch_id,
          "outcomes" => outcomes,
          "costs" => without_key(costs, "batch_id"),
          "review_economics" => unknown_safe(without_key(reviews, "batch_id")),
          "unknowns" => {
            "non_joinable_target_observations" => @ledger.first(
              "SELECT COUNT(*) AS count FROM target_observations WHERE batch_id = ? AND join_status != 'exact'",
              [batch_id]
            ).fetch("count"),
            "unlinked_host_sessions_ledger_wide" => @ledger.first(
              "SELECT COUNT(*) AS count FROM host_sessions WHERE link_status != 'exact'"
            ).fetch("count")
          }
        }
      end

      private

      def without_key(row, key)
        row.each_with_object({}) { |(name, value), result| result[name] = value unless name == key }
      end

      def unknown_safe(row)
        row.transform_values { |value| value.nil? ? "UNKNOWN" : value }
      end
    end
  end
end
