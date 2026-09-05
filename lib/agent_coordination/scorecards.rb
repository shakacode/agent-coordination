# frozen_string_literal: true

module AgentCoord
  module Telemetry
    class Scorecards
      INTERVENTION_KINDS = %w[takeover supersede manual-fix drain].freeze
      HELP_REASONS = %w[blocked-user-input question permission].freeze

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
        operations = @ledger.first("SELECT * FROM operational_event_scorecard WHERE batch_id = ?", [batch_id])
        durations = @ledger.rows(
          "SELECT lane_id, duration_seconds FROM lane_duration_scorecard WHERE batch_id = ? ORDER BY lane_id",
          [batch_id]
        )
        rework = @ledger.first("SELECT reclaims FROM custody_rework_scorecard WHERE batch_id = ?", [batch_id])
        {
          "batch_id" => batch_id,
          "outcomes" => outcomes,
          "costs" => without_key(costs, "batch_id"),
          "review_economics" => unknown_safe(without_key(reviews, "batch_id")),
          "operational_load" => operational_load(operations, durations, rework),
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

      def operational_load(row, durations, rework)
        merged_prs = row.fetch("merged_prs")
        intervention_counts = INTERVENTION_KINDS.to_h do |kind|
          [kind, row.fetch("intervention_#{kind.tr('-', '_')}")]
        end
        help_counts = HELP_REASONS.to_h do |reason|
          [reason, row.fetch("help_#{reason.tr('-', '_')}")]
        end
        {
          "merged_prs" => merged_prs,
          "human_interventions" => {
            "count" => row.fetch("human_interventions"),
            "per_10_merged_prs" => per_ten(row.fetch("human_interventions"), merged_prs),
            "by_kind" => intervention_counts,
            "by_kind_per_10_merged_prs" => normalized_counts(intervention_counts, merged_prs)
          },
          "help_requests" => {
            "count" => row.fetch("help_requests"),
            "per_10_merged_prs" => per_ten(row.fetch("help_requests"), merged_prs),
            "by_reason" => help_counts,
            "by_reason_per_10_merged_prs" => normalized_counts(help_counts, merged_prs)
          },
          "escalations" => normalized_count(row.fetch("escalations"), merged_prs),
          "lane_durations" => lane_durations(durations),
          "custody_rework" => {
            "reclaims" => rework.fetch("reclaims"),
            "per_10_merged_prs" => per_ten(rework.fetch("reclaims"), merged_prs)
          }
        }
      end

      def lane_durations(rows)
        by_lane = rows.to_h do |row|
          [row.fetch("lane_id"), row.fetch("duration_seconds") || "UNKNOWN"]
        end
        known = by_lane.values.grep(Integer).sort
        {
          "lanes" => rows.length,
          "computable_lanes" => known.length,
          "telemetry_gap_lanes" => rows.length - known.length,
          "by_lane_seconds" => by_lane,
          "seconds" => duration_summary(known)
        }
      end

      def duration_summary(durations)
        return { "minimum" => "UNKNOWN", "median" => "UNKNOWN", "maximum" => "UNKNOWN" } if durations.empty?

        middle = durations.length / 2
        median = if durations.length.odd?
                   durations.fetch(middle)
                 else
                   (durations.fetch(middle - 1) + durations.fetch(middle)) / 2.0
                 end
        { "minimum" => durations.first, "median" => median, "maximum" => durations.last }
      end

      def normalized_counts(counts, denominator)
        counts.transform_values { |count| per_ten(count, denominator) }
      end

      def normalized_count(count, denominator)
        { "count" => count, "per_10_merged_prs" => per_ten(count, denominator) }
      end

      def per_ten(count, denominator)
        return "UNKNOWN" if denominator.zero?

        ((count * 10.0) / denominator).round(3)
      end
    end
  end
end
