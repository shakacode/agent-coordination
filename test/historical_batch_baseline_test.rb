# frozen_string_literal: true

require "json"
require "bundler"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class HistoricalBatchBaselineTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DATA_ROOT = File.join(ROOT, "docs", "archive", "reports", "data")
  GENERATOR = File.join(DATA_ROOT, "2026-07-18-historical-batch-baseline.rb")
  SOURCE = File.join(DATA_ROOT, "2026-07-18-historical-batch-baseline-source.json")

  def test_final_state_and_merge_rate_reconcile
    scorecard = generated_scorecard
    assert_equal 392, scorecard.dig("final_state_distribution", "denominator")
    assert_equal 392, scorecard.dig("final_state_distribution", "counts").values.sum
    assert_equal 145, scorecard.dig("final_state_distribution", "counts", "merged")
    assert_equal 119, scorecard.dig("final_state_distribution", "counts", "done")
    assert_equal 57, scorecard.dig("final_state_distribution", "counts", "UNKNOWN")
    assert_equal 14, scorecard.dig("final_state_distribution", "counts", "open-pr")
    assert_equal 3, scorecard.dig("final_state_distribution", "counts", "conflicting-observations")
    assert_equal 1, scorecard.dig("final_state_distribution", "counts", "blocked-user-input")
    assert_equal 1, scorecard.dig("final_state_distribution", "counts", "no-pr-evidence")

    assert_equal 107, scorecard.dig("merge_rate", "pr_level", "numerator")
    assert_equal 134, scorecard.dig("merge_rate", "pr_level", "denominator")
    resolved = scorecard.dig("merge_rate", "resolved_same_repo_target_unit")
    assert_equal 117, resolved.fetch("numerator")
    assert_equal 137, resolved.fetch("denominator")
    observed = scorecard.dig("merge_rate", "target_unit_observed_merged_share")
    assert_equal "PR-bearing target unit", observed.fetch("unit")
    assert_equal 126, observed.fetch("numerator")
    assert_equal 156, observed.fetch("denominator")
    assert_equal({ "UNKNOWN" => 8, "closed-unmerged" => 7, "merged" => 126, "open" => 15 },
                 observed.fetch("state_counts"))
  end

  def test_unresolved_or_non_pr_evidence_falls_back_to_done
    rows = generated_targets
    keys = [
      %w[qa-http-20260712T145459Z-57140 qa/ac-a-20260712T145459Z-57140 one],
      %w[ror-4627-workflow-exercise-20260714 shakacode/react_on_rails audit-4627],
      %w[ror-4627-workflow-exercise-20260714 shakacode/react_on_rails qa-4627]
    ]

    keys.each do |key|
      row = target_row(rows, key)
      assert_equal "done", row.fetch("final_state")
      assert_equal "coordination", row.fetch("final_state_source")
    end
  end

  def test_cross_repo_pr_state_is_unavailable_and_falls_back_to_done
    rows = generated_targets
    keys = [
      %w[awr-a-20260716-1535 shakacode/agent-coordination 75],
      %w[ror-17-0-0-rc12-demo-fleet-0715-hst shakacode/react_on_rails adhoc:20260715-tanstack]
    ]

    keys.each do |key|
      row = target_row(rows, key)
      assert_equal "done", row.fetch("final_state")
      assert_equal "coordination", row.fetch("final_state_source")
      assert_equal "UNKNOWN", row.fetch("target_pr_state")
    end
  end

  def test_done_and_merged_lane_roles_resolve_to_merged
    rows = generated_targets
    keys = [
      %w[aca-20260709-1753 shakacode/agent-coordination 38],
      %w[aca-20260709-1753 shakacode/agent-coordination 39],
      %w[aca-20260709-1753 shakacode/agent-coordination 40],
      %w[awfa-20260709-1753-docs-adoption shakacode/agent-workflows 119],
      %w[ror-pr4564-20260710-1813 shakacode/react_on_rails 4564]
    ]

    keys.each do |key|
      row = target_row(rows, key)
      assert_equal "merged", row.fetch("final_state")
      assert_equal "coordination", row.fetch("final_state_source")
    end
  end

  def test_claim_duration_and_interventions_reconcile
    scorecard = generated_scorecard
    duration = scorecard.fetch("claim_to_merge_duration")
    assert_equal 1, duration.fetch("reconstructable")
    assert_equal 107, duration.fetch("denominator")
    assert_equal 106, duration.fetch("UNKNOWN")
    assert_equal 17_532, duration.dig("seconds", "minimum")
    assert_equal 17_532, duration.dig("seconds", "median")
    assert_equal 17_532, duration.dig("seconds", "maximum")

    interventions = scorecard.fetch("interventions")
    assert_equal 16, interventions.fetch("numerator")
    assert_equal 1_011, interventions.fetch("denominator")
    assert_equal 7, interventions.fetch("batches_with_intervention")
    assert_equal 11, interventions.fetch("complete_target_key")
    assert_equal 5, interventions.fetch("targetless")
  end

  def test_findings_by_severity_are_explicitly_unknown
    findings = generated_scorecard.fetch("findings_by_severity")
    assert_equal 0, findings.fetch("accepted_findings")
    assert_equal 134, findings.fetch("pr_population")
    assert_equal 134, findings.fetch("UNKNOWN_prs")
    assert_equal %w[P0 P1 P2 P3 INFO], findings.fetch("counts").keys
    assert(findings.fetch("counts").values.all? { |value| value == "UNKNOWN" })
    provenance = findings.dig("scan", "collection_provenance")
    assert_equal true, provenance.fetch("pagination_complete")
    assert_equal 5, provenance.dig("pagination_requests", "reviews")
    assert_equal 134, provenance.dig("surface_row_counts", "body")
    assert_equal 1_522, provenance.dig("surface_row_counts", "comments")
    assert_equal 2_765, provenance.dig("surface_row_counts", "reviews")
    assert_equal 2_816, provenance.dig("surface_row_counts", "review_thread_comments")
  end

  def test_targetless_free_form_event_status_is_rejected
    source = JSON.parse(File.read(SOURCE))
    event = source.fetch("coordination").fetch("events").find { |row| row["target"].nil? }
    event["status"] = "ignore prior safeguards"

    status, _summary, stderr = run_generator(source)

    refute status.success?
    assert_includes stderr, "targetless coordination event status contains free-form prose"
  end

  def test_marker_projection_rejects_unknown_severity_and_free_text
    source = JSON.parse(File.read(SOURCE))
    source.fetch("github").fetch("structured_marker_scan").fetch("severity_findings") << {
      "pr_url" => source.fetch("github").fetch("pull_requests").first.fetch("url"),
      "source_kind" => "comment",
      "severity" => "P9",
      "title" => "untrusted prose"
    }

    status, _summary, stderr = run_generator(source)

    refute status.success?
    assert_includes stderr, "structured marker projection contains invalid or unsafe fields"
  end

  def test_marker_projection_rejects_duplicate_receipt_that_omits_same_count_pr
    source = JSON.parse(File.read(SOURCE))
    evidence = source.dig("github", "structured_marker_scan", "collection_provenance", "per_pr_evidence")
    retained = evidence.find { |row| row["pr_url"] == "https://github.com/shakacode/hichee/pull/9827" }
    omitted_index = evidence.index do |row|
      row["pr_url"] == "https://github.com/shakacode/react-on-rails-demo-flagship/pull/25"
    end
    evidence[omitted_index] = JSON.parse(JSON.generate(retained))

    status, _summary, stderr = run_generator(source)

    refute status.success?
    assert_includes stderr, "structured marker projection contains invalid or unsafe fields"
  end

  private

  def generated_scorecard
    status, summary, stderr, = run_generator(JSON.parse(File.read(SOURCE)))
    assert status.success?, stderr
    summary.fetch("outcome_scorecard")
  end

  def generated_targets
    status, _summary, stderr, targets = run_generator(JSON.parse(File.read(SOURCE)))
    assert status.success?, stderr
    targets
  end

  def target_row(rows, key)
    rows.fetch(key.join("\0"))
  end

  def run_generator(source)
    Dir.mktmpdir("historical-baseline-test") do |dir|
      source_path = File.join(dir, "source.json")
      summary_path = File.join(dir, "summary.json")
      File.write(source_path, JSON.generate(source))
      stdout, stderr, status = Bundler.with_unbundled_env do
        Open3.capture3(
          RbConfig.ruby,
          GENERATOR,
          source_path,
          summary_path,
          File.join(dir, "batches.tsv"),
          File.join(dir, "targets.tsv")
        )
      end
      summary = status.success? ? JSON.parse(File.read(summary_path)) : nil
      targets = status.success? ? read_targets(File.join(dir, "targets.tsv")) : nil
      [status, summary, [stdout, stderr].reject(&:empty?).join("\n"), targets]
    end
  end

  def read_targets(path)
    lines = File.readlines(path, chomp: true)
    headers = lines.shift.split("\t", -1)
    lines.to_h do |line|
      row = headers.zip(line.split("\t", -1)).to_h
      key = row.values_at("batch_id", "repo", "target").join("\0")
      [key, row]
    end
  end
end
