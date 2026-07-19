#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "time"

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

targetless_prose_statuses = events.select do |event|
  target = event["target"]
  status = event["status"]
  (target.nil? || target.empty?) && status.is_a?(String) && status.match?(/[[:space:]]/)
end
abort "targetless coordination event status contains free-form prose" unless targetless_prose_statuses.empty?

FINAL_STATE_ALIASES = {
  "abandoned" => "abandoned",
  "active" => "in-progress",
  "blocked" => "blocked",
  "blocked_user_input" => "blocked-user-input",
  "complete" => "done",
  "completed" => "done",
  "done" => "done",
  "external-gate-failing" => "blocked",
  "external_gate_failing" => "blocked",
  "failed" => "failed",
  "heartbeat" => "in-progress",
  "in_progress" => "in-progress",
  "merged" => "merged",
  "no_pr_evidence" => "no-pr-evidence",
  "pending" => "in-progress",
  "ready" => "ready",
  "ready_for_coordinator" => "ready",
  "ready_gates_clean" => "ready",
  "ready_handoff" => "ready",
  "ready_no_merge_authority" => "ready",
  "ready_to_merge" => "ready",
  "superseded" => "superseded",
  "unknown" => "UNKNOWN",
  "waiting" => "waiting",
  "waiting_maintainer_decision" => "waiting",
  "waiting_on_checks_or_review" => "waiting"
}.freeze
EXCEPTIONAL_FINAL_STATES = %w[
  blocked-user-input no-pr-evidence failed abandoned superseded
].freeze
INTERVENTION_TYPES = {
  "MODEL_ESCALATION_REQUEST" => "model-escalation",
  "collision-blocked" => "collision-blocked",
  "dispatch-replaced" => "replacement",
  "lane-takeover" => "replacement",
  "model-escalation" => "model-escalation",
  "replacement" => "replacement",
  "worker-replacement" => "replacement"
}.freeze
SEVERITIES = %w[P0 P1 P2 P3 INFO].freeze
MARKER_SCAN_KEYS = %w[
  captured_at collection_provenance exact_markers fields malformed_severity_candidates
  matching_markers scope_pr_count search_errors severity_findings
].freeze
MARKER_FIELDS = %w[body comments reviews review_thread_comments].freeze
MARKER_SOURCE_KINDS = %w[body comment review review_thread_comment].freeze
MARKER_TYPES = [
  "review-finding-v0",
  "post-merge-audit-finding v1",
  "completed-batch-audit v1",
  "codex-claim v1"
].freeze
SHA256_PATTERN = /\A[0-9a-f]{64}\z/
MARKER_COLLECTOR_CONTRACT = "historical-batch-marker-collector-v1"
MARKER_COLLECTOR_PATH = File.expand_path("2026-07-18-historical-batch-baseline-marker-collector.rb", __dir__)
REVIEW_VALIDATOR_PATH = File.expand_path("2026-07-18-historical-batch-review-finding-validator.rb.source", __dir__)

def final_state(rows, github)
  pr_states = github.fetch(:state_resolved).map { |pr| pr.fetch("state") }.uniq
  coordination_states = rows.filter_map { |row| FINAL_STATE_ALIASES[row["lane_status"]] }.uniq
  exceptional = coordination_states & EXCEPTIONAL_FINAL_STATES

  return %w[merged github] if pr_states.include?("MERGED")
  return [exceptional.first, "coordination"] if exceptional.one?
  return %w[conflicting-observations coordination] if exceptional.length > 1
  return %w[open-pr github] if pr_states.include?("OPEN")
  return %w[closed-unmerged github] if pr_states.include?("CLOSED")

  recognized = coordination_states.reject { |state| state == "UNKNOWN" }
  return %w[merged coordination] if recognized.include?("merged") && (recognized - %w[done merged]).empty?
  return [recognized.first, "coordination"] if recognized.one?
  return %w[UNKNOWN github-unavailable] if recognized.empty? && github.fetch(:has_pr_url)
  return %w[UNKNOWN coordination] if recognized.empty?

  %w[conflicting-observations coordination]
end

def target_pr_state(github)
  states = github.fetch(:state_resolved).map { |pr| pr.fetch("state") }.uniq
  return "merged" if states.include?("MERGED")
  return "open" if states.include?("OPEN")
  return "closed-unmerged" if states.include?("CLOSED")

  "UNKNOWN"
end

def valid_marker_projection?(marker, github_prs)
  marker.is_a?(Hash) && marker.keys.sort == %w[marker pr_url source_kind] &&
    github_prs.key?(marker["pr_url"]) && MARKER_SOURCE_KINDS.include?(marker["source_kind"]) &&
    MARKER_TYPES.include?(marker["marker"])
end

def valid_severity_projection?(finding, github_prs)
  finding.is_a?(Hash) && finding.keys.sort == %w[pr_url severity source_kind] &&
    github_prs.key?(finding["pr_url"]) && MARKER_SOURCE_KINDS.include?(finding["source_kind"]) &&
    SEVERITIES.include?(finding["severity"])
end

def valid_collection_provenance?(provenance, github_prs)
  keys = %w[
    archived_collector_sha256 capture_collector_sha256 collector_contract graphql_requests
    pagination_complete pagination_requests per_pr_evidence query_evidence_sha256
    response_evidence_sha256 review_finding_validator_sha256 scope_pr_url_set_sha256 surface_row_counts
  ]
  return false unless provenance.is_a?(Hash) && provenance.keys.sort == keys.sort
  return false unless valid_collection_provenance_header?(provenance)

  evidence = provenance["per_pr_evidence"]
  evidence.is_a?(Array) && evidence.length == github_prs.length &&
    evidence.all? { |row| valid_per_pr_marker_evidence?(row, github_prs) } &&
    exact_marker_evidence_urls?(provenance, evidence, github_prs.keys) &&
    aggregate_marker_evidence?(provenance, evidence, github_prs.length)
end

def valid_collection_provenance_header?(provenance)
  digests = %w[
    archived_collector_sha256 capture_collector_sha256 query_evidence_sha256
    response_evidence_sha256 review_finding_validator_sha256 scope_pr_url_set_sha256
  ]
  collector_sha = Digest::SHA256.file(MARKER_COLLECTOR_PATH).hexdigest
  provenance["collector_contract"] == MARKER_COLLECTOR_CONTRACT &&
    digests.all? { |key| SHA256_PATTERN.match?(provenance[key].to_s) } &&
    provenance["capture_collector_sha256"] == provenance["archived_collector_sha256"] &&
    provenance["archived_collector_sha256"] == collector_sha &&
    provenance["review_finding_validator_sha256"] == Digest::SHA256.file(REVIEW_VALIDATOR_PATH).hexdigest &&
    provenance["graphql_requests"].is_a?(Integer) && provenance["graphql_requests"].positive? &&
    provenance["pagination_complete"] == true &&
    %w[surface_row_counts pagination_requests].all? { |key| valid_marker_count_hash?(provenance[key]) }
end

def exact_marker_evidence_urls?(provenance, evidence, expected_urls)
  actual_urls = evidence.map { |row| row.fetch("pr_url") }
  actual_urls.length == actual_urls.uniq.length && actual_urls.sort == expected_urls.sort &&
    provenance["scope_pr_url_set_sha256"] == canonical_url_set_sha256(actual_urls)
end

def canonical_url_set_sha256(urls)
  Digest::SHA256.hexdigest(JSON.generate(urls.sort))
end

def valid_marker_count_hash?(value)
  value.is_a?(Hash) && value.keys == MARKER_FIELDS &&
    value.values.all? { |count| count.is_a?(Integer) && count >= 0 }
end

def valid_per_pr_marker_evidence?(row, github_prs)
  keys = %w[pagination_complete pagination_requests pr_url surface_digest_sha256 surface_row_counts]
  row.is_a?(Hash) && row.keys.sort == keys.sort && row["pagination_complete"] == true &&
    github_prs.key?(row["pr_url"]) && SHA256_PATTERN.match?(row["surface_digest_sha256"].to_s) &&
    %w[surface_row_counts pagination_requests].all? { |key| valid_marker_count_hash?(row[key]) }
end

def aggregate_marker_evidence?(provenance, evidence, scope_count)
  expected_rows = MARKER_FIELDS.to_h do |field|
    [field, evidence.sum { |row| row.dig("surface_row_counts", field) }]
  end
  expected_pagination = MARKER_FIELDS.to_h do |field|
    [field, evidence.sum { |row| row.dig("pagination_requests", field) }]
  end
  provenance["surface_row_counts"] == expected_rows &&
    provenance["pagination_requests"] == expected_pagination && expected_rows["body"] == scope_count
end

def validate_marker_scan!(scan, github_prs)
  valid = scan.is_a?(Hash) && scan.keys.sort == MARKER_SCAN_KEYS.sort
  valid &&= scan["scope_pr_count"] == github_prs.length
  valid &&= scan["fields"] == MARKER_FIELDS && scan["exact_markers"] == MARKER_TYPES
  valid &&= valid_collection_provenance?(scan["collection_provenance"], github_prs)
  valid &&= scan["malformed_severity_candidates"].is_a?(Integer) &&
            scan["malformed_severity_candidates"].zero? && scan["search_errors"] == []
  valid &&= scan.fetch("matching_markers", []).all? { |row| valid_marker_projection?(row, github_prs) }
  valid &&= scan.fetch("severity_findings", []).all? { |row| valid_severity_projection?(row, github_prs) }
  abort "structured marker projection contains invalid or unsafe fields" unless valid
end

def median(values)
  return nil if values.empty?

  sorted = values.sort
  midpoint = sorted.length / 2
  return sorted[midpoint] if sorted.length.odd?

  (sorted[midpoint - 1] + sorted[midpoint]) / 2.0
end

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
    observed_final_state, final_state_source = final_state(rows, github)
    observed_target_pr_state = target_pr_state(github)
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
      "target_pr_state" => observed_target_pr_state,
      "final_state" => observed_final_state,
      "final_state_source" => final_state_source,
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
    state_usable = invalid.empty? && unresolved.empty? && mismatched.empty?
    gate = github_gate(pr_urls, passing)
    resolved = pr_urls.filter_map { |url| @github_prs[url] }
    { gate: gate, has_pr_url: pr_urls.any?, invalid: invalid, unresolved: unresolved, mismatched: mismatched,
      resolved: resolved, state_resolved: state_usable ? resolved : [] }
  end

  def github_gate(pr_urls, passing)
    return "not_applicable" if pr_urls.empty?

    passing ? "pass" : "fail"
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

final_state_counts = targets.group_by { |row| row.fetch("final_state") }.transform_values(&:length).sort.to_h
final_state_source_counts = targets.group_by do |row|
  row.fetch("final_state_source")
end.transform_values(&:length).sort.to_h
pr_bearing_targets = targets.select { |row| row.fetch("pr_url_count").positive? }
target_pr_state_counts = pr_bearing_targets.map { |row| row.fetch("target_pr_state") }.tally.sort.to_h
resolved_same_repo_targets = pr_bearing_targets.select { |row| row.fetch("github_gate") == "pass" }
resolved_same_repo_merged = resolved_same_repo_targets.count { |row| row.fetch("target_pr_state") == "merged" }

merged_prs = github_prs.values.select { |pr| pr.fetch("state") == "MERGED" }
claim_duration_samples = merged_prs.filter_map do |pr|
  matching_claims = claims.select { |claim| claim["pr_url"] == pr.fetch("url") }
  keys = matching_claims.map { |claim| claim.values_at("batch_id", "repo", "target") }.uniq
  next unless keys.one? && keys.first.all?

  matching_events = events.select do |event|
    event["type"] == "claim" && event.values_at("batch_id", "repo", "target") == keys.first
  end
  next unless matching_events.one? && pr["merged_at"]

  claim_at = Time.iso8601(matching_events.first.fetch("at"))
  merged_at = Time.iso8601(pr.fetch("merged_at"))
  next unless merged_at >= claim_at

  {
    "batch_id" => keys.first.fetch(0),
    "pr_url" => pr.fetch("url"),
    "claim_at" => claim_at.utc.iso8601,
    "merged_at" => merged_at.utc.iso8601,
    "seconds" => (merged_at - claim_at).to_i
  }
end
claim_duration_seconds = claim_duration_samples.map { |sample| sample.fetch("seconds") }

intervention_events = events.filter_map do |event|
  classification = INTERVENTION_TYPES[event["type"]]
  next unless classification

  event.merge("classification" => classification)
end
intervention_type_counts = intervention_events.map { |event| event.fetch("type") }.tally.sort.to_h
intervention_class_counts = intervention_events.map { |event| event.fetch("classification") }.tally.sort.to_h

marker_scan = source.fetch("github").fetch("structured_marker_scan")
validate_marker_scan!(marker_scan, github_prs)
severity_findings = marker_scan.fetch("severity_findings")
marker_provenance = marker_scan.fetch("collection_provenance")
marker_provenance_summary = marker_provenance.except("per_pr_evidence")
marker_provenance_summary["per_pr_evidence_count"] = marker_provenance.fetch("per_pr_evidence").length
observed_severity_counts = SEVERITIES.to_h do |severity|
  [severity, severity_findings.count { |row| row["severity"] == severity }]
end
population_severity_counts = SEVERITIES.to_h { |severity| [severity, "UNKNOWN"] }
claim_duration_mean = if claim_duration_seconds.empty?
                        nil
                      else
                        (claim_duration_seconds.sum.to_f / claim_duration_seconds.length).round(1)
                      end

outcome_metric_gaps = [
  {
    "gap" => "structured_severity_finding_marker_absent",
    "unavailable_units" => github_prs.length,
    "denominator" => github_prs.length,
    "unit" => "resolved unique GitHub PR",
    "metric" => "findings by severity"
  },
  {
    "gap" => "claim_acquired_at_bound_to_pr_absent",
    "unavailable_units" => merged_prs.length - claim_duration_samples.length,
    "denominator" => merged_prs.length,
    "unit" => "merged unique GitHub PR",
    "metric" => "claim-to-merge duration"
  },
  {
    "gap" => "final_state_unavailable",
    "unavailable_units" => final_state_counts.fetch("UNKNOWN", 0),
    "denominator" => targets.length,
    "unit" => "target unit",
    "metric" => "final-state distribution"
  },
  {
    "gap" => "intervention_target_key_absent",
    "unavailable_units" => intervention_events.count { |event| event["target"].nil? },
    "denominator" => intervention_events.length,
    "unit" => "strictly classified intervention event",
    "metric" => "per-target intervention attribution"
  }
].sort_by { |row| [-row.fetch("unavailable_units"), row.fetch("gap")] }

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
    "final_states" => rows.map { |row| row.fetch("final_state") }.tally.sort.to_h,
    "pr_bearing_target_units" => rows.count { |row| row.fetch("pr_url_count").positive? },
    "merged_target_units" => rows.count do |row|
      row.fetch("pr_url_count").positive? && row.fetch("target_pr_state") == "merged"
    end,
    "interventions" => intervention_events.count { |event| event["batch_id"] == batch_id },
    "claim_to_merge_reconstructable" => claim_duration_samples.count { |sample| sample["batch_id"] == batch_id },
    "findings_by_severity" => "UNKNOWN",
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
  "version" => 2,
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
    },
    "final_state" => {
      "unit" => "unique batch_id + repo + target after lane-role aggregation",
      "precedence" => [
        "eligible resolved MERGED PR (invalid, unresolved, and cross-repository evidence excluded)",
        "explicit exceptional lane status",
        "eligible resolved OPEN or CLOSED PR",
        "one unambiguous normalized lane status or compatible done + merged success observations",
        "UNKNOWN or conflicting-observations"
      ],
      "exceptional_lane_statuses" => EXCEPTIONAL_FINAL_STATES,
      "absence_policy" => "missing evidence is never promoted to a final state"
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
  "outcome_scorecard" => {
    "final_state_distribution" => {
      "unit" => "target unit",
      "denominator" => targets.length,
      "counts" => final_state_counts,
      "source_counts" => final_state_source_counts
    },
    "merge_rate" => {
      "pr_level" => {
        "unit" => "resolved unique GitHub PR",
        "numerator" => merged_prs.length,
        "denominator" => github_prs.length,
        "rate_percent" => ((100.0 * merged_prs.length) / github_prs.length).round(1)
      },
      "resolved_same_repo_target_unit" => {
        "unit" => "PR-bearing target unit with resolved same-repo PR evidence",
        "numerator_definition" => "target unit with at least one currently merged resolved same-repo PR",
        "numerator" => resolved_same_repo_merged,
        "denominator" => resolved_same_repo_targets.length,
        "rate_percent" => ((100.0 * resolved_same_repo_merged) / resolved_same_repo_targets.length).round(1)
      },
      "target_unit_observed_merged_share" => {
        "unit" => "PR-bearing target unit",
        "numerator_definition" => [
          "target unit with at least one currently merged resolved PR after excluding explicit",
          "invalid, unresolved, and cross-repository evidence"
        ].join(" "),
        "numerator" => target_pr_state_counts.fetch("merged", 0),
        "denominator" => pr_bearing_targets.length,
        "rate_percent" => ((100.0 * target_pr_state_counts.fetch("merged", 0)) /
                           pr_bearing_targets.length).round(1),
        "interpretation" => [
          "lower-bound observed current merged share; unavailable evidence remains in the denominator,",
          "so this is not a complete historical merge rate"
        ].join(" "),
        "state_counts" => target_pr_state_counts,
        "unavailable_evidence" => {
          "invalid_or_unresolved_target_units" => targets.count do |row|
            row.fetch("gaps").include?("github_pr_url_invalid_or_unresolved")
          end,
          "github_repo_mismatch_target_units" => targets.count do |row|
            row.fetch("gaps").include?("github_repo_mismatch")
          end
        }
      }
    },
    "claim_to_merge_duration" => {
      "unit" => "merged unique GitHub PR",
      "denominator" => merged_prs.length,
      "reconstructable" => claim_duration_samples.length,
      "UNKNOWN" => merged_prs.length - claim_duration_samples.length,
      "join" => [
        "exact type=claim event timestamp + exact batch_id/repo/target current claim carrying PR URL +",
        "that same PR's merged_at"
      ].join(" "),
      "seconds" => {
        "minimum" => claim_duration_seconds.min,
        "median" => median(claim_duration_seconds),
        "maximum" => claim_duration_seconds.max,
        "mean" => claim_duration_mean
      }
    },
    "interventions" => {
      "unit" => "coordination event with an allowlisted structured type",
      "numerator" => intervention_events.length,
      "denominator" => events.length,
      "batches_with_intervention" => intervention_events.map { |event| event.fetch("batch_id") }.uniq.length,
      "batch_denominator" => batches.length,
      "complete_target_key" => intervention_events.count do |event|
        event.values_at("batch_id", "repo", "target").all?
      end,
      "targetless" => intervention_events.count { |event| event["target"].nil? },
      "by_class" => intervention_class_counts,
      "by_type" => intervention_type_counts
    },
    "findings_by_severity" => {
      "unit" => "strict review-finding-v0 finding",
      "pr_population" => github_prs.length,
      "accepted_findings" => severity_findings.length,
      "observed_counts" => observed_severity_counts,
      "counts" => population_severity_counts,
      "UNKNOWN_prs" => github_prs.length,
      "non_severity_marker_prs" => marker_scan.fetch("matching_markers").map { |row| row.fetch("pr_url") }.uniq.length,
      "scan" => {
        "captured_at" => marker_scan.fetch("captured_at"),
        "surfaces" => marker_scan.fetch("fields"),
        "collection_provenance" => marker_provenance_summary
      },
      "disposition" => [
        "UNKNOWN: no severity-bearing structured finding block was present in scanned PR bodies, issue comments,",
        "review bodies, or inline review comments;",
        "absence is not zero findings"
      ].join(" ")
    },
    "metric_gap_ranking" => outcome_metric_gaps
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
abort "final-state denominator drift" unless final_state_counts.values.sum == targets.length
abort "final-state source drift" unless final_state_source_counts.values.sum == targets.length
pr_level_merge_reconciled = merged_prs.length == github_counts.fetch("MERGED", 0) &&
                            github_prs.length == github_counts.values.sum
abort "PR-level merge denominator drift" unless pr_level_merge_reconciled
abort "target-unit merge denominator drift" unless target_pr_state_counts.values.sum == pr_bearing_target_units
abort "same-repo merge denominator drift" unless resolved_same_repo_targets.length ==
                                                 targets.count { |row| row.fetch("github_gate") == "pass" }
claim_duration_unknown = merged_prs.length - claim_duration_samples.length
claim_duration_reconciled = claim_duration_samples.length + claim_duration_unknown == merged_prs.length
abort "claim-to-merge denominator drift" unless claim_duration_reconciled
abort "intervention classification drift" unless intervention_type_counts.values.sum == intervention_events.length &&
                                                 intervention_class_counts.values.sum == intervention_events.length
abort "intervention attribution drift" unless intervention_events.count { |event| event["target"].nil? } +
                                              intervention_events.count do |event|
                                                event.values_at("batch_id", "repo", "target").all?
                                              end == intervention_events.length
abort "severity finding drift" unless observed_severity_counts.values.sum == severity_findings.length
abort "batch final-state drift" unless batch_scores.sum do |row|
  row.fetch("final_states").values.sum
end == targets.length

File.write(summary_path, "#{JSON.pretty_generate(summary)}\n")

batch_headers = %w[
  batch_id repo batch_status synthetic target_units reconstructable observed_only unknown
  final_states pr_bearing_target_units merged_target_units interventions
  claim_to_merge_reconstructable findings_by_severity score_numerator score_denominator score_percent
]
CSV.open(batches_path, "w", col_sep: "\t") do |csv|
  csv << batch_headers
  batch_scores.each do |row|
    csv << batch_headers.map do |header|
      value = row[header]
      value.is_a?(Hash) ? value.map { |key, count| "#{key}=#{count}" }.join("|") : value
    end
  end
end

target_headers = %w[
  batch_id repo target lanes lane_statuses key_complete exact_claim_count
  exact_event_count coordination_exact terminal_observed pr_url_count github_gate
  github_states target_pr_state final_state final_state_source present_head_check_rollups reconstruction score_numerator
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
