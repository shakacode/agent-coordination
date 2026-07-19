#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"

abort "usage: #{$PROGRAM_NAME} SOURCE_JSON SUMMARY_JSON BATCHES_TSV TARGETS_TSV" unless ARGV.length == 4

source_path, summary_path, batches_path, targets_path = ARGV
source = JSON.parse(File.read(source_path))

terminal_statuses = source.fetch("coordination").fetch("terminal_statuses")
terminal_markers = source.fetch("coordination").fetch("terminal_markers")
batches = source.fetch("coordination").fetch("batches")
batch_lookup = batches.to_h { |batch| [batch.fetch("batch_id"), batch] }
claims = source.fetch("coordination").fetch("claims")
events = source.fetch("coordination").fetch("events")
github_prs = source.fetch("github").fetch("pull_requests").to_h { |pr| [pr.fetch("url"), pr] }

class TargetScorer
  def initialize(claim_groups:, event_groups:, github_prs:, terminal_statuses:, terminal_markers:)
    @claim_groups = claim_groups
    @event_groups = event_groups
    @github_prs = github_prs
    @terminal_statuses = terminal_statuses
    @terminal_markers = terminal_markers
  end

  def call(key, rows)
    batch_id, repo, target = key
    exact_claims = @claim_groups.fetch(key, [])
    exact_events = @event_groups.fetch(key, [])
    pr_urls = rows.filter_map { |row| row["pr_url"] }.uniq.sort
    key_complete = key.all? { |value| present?(value) }
    coordination_exact = exact_claims.any? || exact_events.any?
    terminal_observed = terminal_observed?(rows, exact_claims, exact_events)
    github = github_facts(pr_urls, repo, key_complete)
    gaps = gaps(repo, coordination_exact, terminal_observed, github)
    reconstruction = reconstruction(key_complete, coordination_exact, terminal_observed, github.fetch(:gate))
    numerator, denominator = score(key_complete, coordination_exact, terminal_observed, github.fetch(:gate))

    {
      "batch_id" => batch_id,
      "repo" => repo,
      "target" => target,
      "lane_count" => rows.length,
      "lanes" => rows.map { |row| row.fetch("lane") }.uniq.sort,
      "lane_statuses" => rows.filter_map { |row| row["lane_status"] }.uniq.sort,
      "key_complete" => key_complete,
      "exact_claim_count" => exact_claims.length,
      "exact_event_count" => exact_events.length,
      "coordination_exact" => coordination_exact,
      "terminal_observed" => terminal_observed,
      "pr_url_count" => pr_urls.length,
      "pr_urls" => pr_urls,
      "github_gate" => github.fetch(:gate),
      "github_states" => github.fetch(:resolved).map { |pr| pr.fetch("state") }.uniq.sort,
      "present_head_check_rollups" => github.fetch(:resolved)
                                            .map { |pr| pr.fetch("present_head_check_rollup") }.uniq.sort,
      "reconstruction" => reconstruction,
      "score_numerator" => numerator,
      "score_denominator" => denominator,
      "gaps" => gaps
    }
  end

  private

  def present?(value)
    !value.nil? && !value.empty?
  end

  def terminal_observed?(rows, claims, events)
    rows.any? { |row| terminal?(row["lane_status"], row["lane_terminal"]) } ||
      claims.any? { |claim| terminal?(claim["status"], claim["terminal"]) } ||
      events.any? { |event| terminal?(event["status"], event["terminal"]) }
  end

  def terminal?(status, marker)
    @terminal_statuses.include?(status) || @terminal_markers.include?(marker)
  end

  def github_facts(pr_urls, repo, key_complete)
    invalid = pr_urls.reject { |url| github_pull_url?(url) }
    unresolved = pr_urls.select { |url| github_pull_url?(url) && !@github_prs.key?(url) }
    mismatched = pr_urls.select do |url|
      github_pull_url?(url) && present?(repo) && github_repo(url).downcase != repo.downcase
    end
    passing = invalid.empty? && unresolved.empty? && mismatched.empty? && key_complete
    gate = if pr_urls.empty?
             "not_applicable"
           else
             (passing ? "pass" : "fail")
           end
    { gate: gate, invalid: invalid, unresolved: unresolved, mismatched: mismatched,
      resolved: pr_urls.filter_map { |url| @github_prs[url] } }
  end

  def github_pull_url?(url)
    %r{\Ahttps://github\.com/[^/]+/[^/]+/pull/\d+\z}.match?(url)
  end

  def github_repo(url)
    url[%r{\Ahttps://github\.com/([^/]+/[^/]+)/pull/\d+\z}, 1]
  end

  def gaps(repo, coordination_exact, terminal_observed, github)
    values = []
    values << "missing_repo_join_component" unless present?(repo)
    values << "no_exact_coordination_match" unless coordination_exact
    values << "no_terminal_outcome_observed" unless terminal_observed
    values << "github_pr_url_invalid_or_unresolved" unless github.fetch(:invalid).empty? &&
                                                           github.fetch(:unresolved).empty?
    values << "github_repo_mismatch" unless github.fetch(:mismatched).empty?
    values
  end

  def reconstruction(key_complete, coordination_exact, terminal_observed, github_gate)
    return "reconstructable" if key_complete && coordination_exact && terminal_observed && github_gate != "fail"
    return "observed_only" if terminal_observed

    "UNKNOWN"
  end

  def score(key_complete, coordination_exact, terminal_observed, github_gate)
    numerator = [key_complete, coordination_exact, terminal_observed].count(true)
    denominator = 3
    return [numerator, denominator] if github_gate == "not_applicable"

    [numerator + (github_gate == "pass" ? 1 : 0), denominator + 1]
  end
end

exploded = batches.flat_map do |batch|
  batch.fetch("lanes").flat_map do |lane|
    lane.fetch("targets").map do |target|
      {
        "batch_id" => batch.fetch("batch_id"),
        "repo" => batch["repo"],
        "target" => target,
        "batch_status" => batch["status"],
        "registered_at" => batch["registered_at"],
        "updated_at" => batch["updated_at"],
        "synthetic" => batch.fetch("synthetic", false),
        "lane" => lane.fetch("name"),
        "lane_status" => lane["status"],
        "lane_terminal" => lane["terminal"],
        "branch" => lane["branch"],
        "pr_url" => lane["pr_url"]
      }
    end
  end
end

target_groups = exploded.group_by { |row| row.values_at("batch_id", "repo", "target") }
claim_groups = claims.group_by { |row| row.values_at("batch_id", "repo", "target") }
event_groups = events.group_by { |row| row.values_at("batch_id", "repo", "target") }

scorer = TargetScorer.new(claim_groups: claim_groups, event_groups: event_groups, github_prs: github_prs,
                          terminal_statuses: terminal_statuses, terminal_markers: terminal_markers)
targets = target_groups.map { |key, rows| scorer.call(key, rows) }
targets.sort_by! { |row| [row.fetch("batch_id"), row["repo"].to_s, row.fetch("target")] }

batch_scores = targets.group_by { |row| row.fetch("batch_id") }.map do |batch_id, rows|
  batch = batch_lookup.fetch(batch_id)
  numerator = rows.sum { |row| row.fetch("score_numerator") }
  denominator = rows.sum { |row| row.fetch("score_denominator") }
  classes = rows.group_by { |row| row.fetch("reconstruction") }.transform_values(&:length)
  {
    "batch_id" => batch_id,
    "repo" => batch["repo"],
    "batch_status" => batch["status"],
    "synthetic" => batch.fetch("synthetic", false),
    "target_units" => rows.length,
    "reconstructable" => classes.fetch("reconstructable", 0),
    "observed_only" => classes.fetch("observed_only", 0),
    "unknown" => classes.fetch("UNKNOWN", 0),
    "score_numerator" => numerator,
    "score_denominator" => denominator,
    "score_percent" => ((100.0 * numerator) / denominator).round(1)
  }
end
batch_scores.sort_by! { |row| [-row.fetch("score_percent"), row.fetch("batch_id")] }

nonreconstructable = targets.reject { |row| row.fetch("reconstruction") == "reconstructable" }
gap_counts = nonreconstructable.flat_map { |row| row.fetch("gaps") }.tally
pr_bearing_target_units = targets.count { |row| row.fetch("pr_url_count").positive? }
gap_denominators = {
  "no_exact_coordination_match" => targets.length,
  "no_terminal_outcome_observed" => targets.length,
  "missing_repo_join_component" => targets.length,
  "github_pr_url_invalid_or_unresolved" => pr_bearing_target_units,
  "github_repo_mismatch" => pr_bearing_target_units
}
gap_ranking = gap_counts.map do |name, count|
  {
    "gap" => name,
    "blocked_target_units" => count,
    "denominator" => gap_denominators.fetch(name),
    "scope" => "outcome evidence score",
    "score_blocking" => true
  }
end
gap_ranking << {
  "gap" => "historical_ci_at_event_time_absent",
  "blocked_target_units" => pr_bearing_target_units,
  "denominator" => pr_bearing_target_units,
  "scope" => "historical CI reconstruction; current-head rollup is not a substitute",
  "score_blocking" => false
}
gap_ranking.sort_by! { |row| [-row.fetch("blocked_target_units"), row.fetch("gap")] }

complete_targets = targets.select { |row| row.fetch("key_complete") }
collision_groups = complete_targets.group_by do |row|
  row.values_at("repo", "target")
end
reduced_collisions = collision_groups.filter_map do |(repo, target), rows|
  batch_ids = rows.map { |row| row.fetch("batch_id") }.uniq.sort
  next if batch_ids.one?

  { "repo" => repo, "target" => target, "batch_ids" => batch_ids }
end
reduced_collisions.sort_by! { |row| [row.fetch("repo"), row.fetch("target")] }

multi_lane_keys = targets.select { |row| row.fetch("lane_count") > 1 }
representative_keys = [
  ["ac-a-0712-0107", "shakacode/agent-coordination", "51"],
  ["ac-b-0712-0107", "shakacode/agent-coordination", "8"],
  ["acb", "shakacode/agent-coordination", "8"],
  ["ac-a-coord-cinder", "shakacode/agent-coordination", "54"]
]
representative_rows = representative_keys.filter_map do |key|
  targets.find { |row| row.values_at("batch_id", "repo", "target") == key }
end
representative_rows << targets.find { |row| !row.fetch("key_complete") }
representative_rows.compact!

github_counts = source.fetch("github").fetch("pull_requests").group_by do |pr|
  pr.fetch("state")
end.transform_values(&:length)
check_counts = source.fetch("github").fetch("pull_requests")
                     .group_by { |pr| pr.fetch("present_head_check_rollup") }.transform_values(&:length)
classification_counts = targets.group_by { |row| row.fetch("reconstruction") }.transform_values(&:length)

summary = {
  "contract" => "historical-batch-baseline",
  "version" => 1,
  "captured_at" => source.fetch("captured_at"),
  "provenance" => source.fetch("provenance"),
  "method" => {
    "population" => "all batch manifests in one successful unscoped status --include-archived snapshot",
    "unit" => "unique batch_id + repo + target after exploding and aggregating lane target arrays",
    "score" => [
      "one point each for complete join key, exact claim/event match, observed terminal outcome,",
      "and resolved same-repo GitHub PR when a PR URL is recorded"
    ].join(" "),
    "score_denominator" => "3 per target unit plus 1 only when that target unit records a PR URL",
    "classification" => {
      "reconstructable" => [
        "complete key + exact claim/event + terminal observation +",
        "passing/not-applicable GitHub gate"
      ].join(" "),
      "observed_only" => "terminal outcome is directly observed but at least one reconstruction gate fails",
      "UNKNOWN" => "no recognized terminal outcome is directly observed"
    }
  },
  "headline" => {
    "batches" => batches.length,
    "synthetic_batches" => batches.count { |batch| batch.fetch("synthetic", false) },
    "lane_rows" => batches.sum { |batch| batch.fetch("lanes").length },
    "exploded_target_rows" => exploded.length,
    "target_units" => targets.length,
    "target_units_complete_key" => targets.count { |row| row.fetch("key_complete") },
    "target_units_exact_coordination" => targets.count { |row| row.fetch("coordination_exact") },
    "target_units_terminal_observed" => targets.count { |row| row.fetch("terminal_observed") },
    "target_units_with_pr_url" => targets.count { |row| row.fetch("pr_url_count").positive? },
    "classification" => {
      "reconstructable" => classification_counts.fetch("reconstructable", 0),
      "observed_only" => classification_counts.fetch("observed_only", 0),
      "UNKNOWN" => classification_counts.fetch("UNKNOWN", 0)
    },
    "batch_score_numerator" => batch_scores.sum { |row| row.fetch("score_numerator") },
    "batch_score_denominator" => batch_scores.sum { |row| row.fetch("score_denominator") },
    "overall_score_percent" => begin
      numerator = batch_scores.sum { |row| row.fetch("score_numerator") }
      denominator = batch_scores.sum { |row| row.fetch("score_denominator") }
      ((100.0 * numerator) / denominator).round(1)
    end
  },
  "join_validation" => {
    "repo_target_keys_spanning_batches" => reduced_collisions.length,
    "full_keys_with_multiple_lane_rows" => multi_lane_keys.length,
    "extra_lane_rows_collapsed" => exploded.length - targets.length,
    "conclusion" => [
      "batch_id prevents observed cross-batch repo+target collisions;",
      "the triple is a target-level join key only after lane-role aggregation"
    ].join(" "),
    "reduced_key_collisions" => reduced_collisions,
    "representative_rows" => representative_rows
  },
  "reconstruction_gap_ranking" => gap_ranking,
  "platform_caveats" => {
    "archive_records" => source.fetch("coordination").fetch("counts").fetch("archive"),
    "pr_bearing_target_units_without_historical_ci_at_event_time" => pr_bearing_target_units,
    "github_pr_metadata" => github_counts,
    "present_head_check_rollups" => check_counts,
    "github_graphql_errors" => source.fetch("github").fetch("errors")
  },
  "batch_scores" => batch_scores
}

source_counts = source.fetch("coordination").fetch("counts")
abort "batch count drift" unless source_counts.fetch("batches") == batches.length
abort "duplicate batch_id" unless batches.map { |batch| batch.fetch("batch_id") }.uniq.length == batches.length
abort "target classification drift" unless classification_counts.values.sum == targets.length
abort "batch target total drift" unless batch_scores.sum { |row| row.fetch("target_units") } == targets.length
abort "score denominator drift" unless batch_scores.sum { |row| row.fetch("score_denominator") } ==
                                       (targets.length * 3) + pr_bearing_target_units
abort "exploded row drift" unless targets.sum { |row| row.fetch("lane_count") } == exploded.length

File.write(summary_path, "#{JSON.pretty_generate(summary)}\n")

batch_headers = %w[
  batch_id repo batch_status synthetic target_units reconstructable observed_only unknown
  score_numerator score_denominator score_percent
]
CSV.open(batches_path, "w", col_sep: "\t") do |csv|
  csv << batch_headers
  batch_scores.each { |row| csv << batch_headers.map { |header| row[header] } }
end

target_headers = %w[
  batch_id repo target lanes lane_statuses key_complete exact_claim_count
  exact_event_count coordination_exact terminal_observed pr_url_count github_gate
  github_states present_head_check_rollups reconstruction score_numerator
  score_denominator gaps
]
CSV.open(targets_path, "w", col_sep: "\t") do |csv|
  csv << target_headers
  targets.each do |row|
    csv << target_headers.map do |header|
      value = row[header]
      value.is_a?(Array) ? value.join("|") : value
    end
  end
end
