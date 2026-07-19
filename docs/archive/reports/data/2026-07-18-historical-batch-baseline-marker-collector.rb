#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"

REVIEW_VALIDATOR_PATH = File.expand_path("2026-07-18-historical-batch-review-finding-validator.rb.source", __dir__)
load REVIEW_VALIDATOR_PATH

FIELDS = %w[body comments reviews review_thread_comments].freeze
SOURCE_KINDS = {
  "body" => "body",
  "comments" => "comment",
  "reviews" => "review",
  "review_thread_comments" => "review_thread_comment"
}.freeze
MARKERS = [
  "review-finding-v0",
  "post-merge-audit-finding v1",
  "completed-batch-audit v1",
  "codex-claim v1"
].freeze
HTML_MARKERS = MARKERS.drop(1).freeze
REVIEW_SCHEMA = "review-finding-v0"
SEVERITIES = %w[P0 P1 P2 P3 INFO].freeze
COLLECTOR_CONTRACT = "historical-batch-marker-collector-v1"
FIXTURE_CONTRACT = "historical-batch-marker-fixture-v1"
SHA256_PATTERN = /\A[0-9a-f]{64}\z/

def sha256_file(path)
  Digest::SHA256.file(path).hexdigest
end

def paginated_bodies(endpoint, response_digest)
  stdout, stderr, status = Open3.capture3("gh", "api", "--paginate", "--slurp", endpoint)
  return [nil, stderr] unless status.success?

  response_digest.update(stdout)
  [JSON.parse(stdout).flatten.map { |row| row["body"] }, nil]
end

def valid_fixture?(fixture)
  return false unless fixture.is_a?(Hash)

  expected = %w[captured_at contract graphql_requests pagination_complete pull_requests]
  return false unless fixture.keys.sort == expected && fixture["contract"] == FIXTURE_CONTRACT
  return false unless fixture["graphql_requests"].is_a?(Integer) && fixture["graphql_requests"].positive?
  return false unless [true, false].include?(fixture["pagination_complete"])

  fixture["pull_requests"].is_a?(Array) && fixture["pull_requests"].all? do |pr|
    valid_fixture_pr?(pr)
  end
end

def valid_fixture_pr?(pull_request)
  keys = %w[number pagination_requests repository surfaces url]
  return false unless pull_request.is_a?(Hash) && pull_request.keys.sort == keys
  return false unless pull_request["repository"].is_a?(String) && pull_request["number"].is_a?(Integer)

  expected_url = "https://github.com/#{pull_request.fetch('repository')}/pull/#{pull_request.fetch('number')}"
  return false unless pull_request["url"] == expected_url

  valid_fixture_surfaces?(pull_request["surfaces"]) &&
    valid_fixture_pagination?(pull_request["pagination_requests"])
end

def valid_fixture_surfaces?(surfaces)
  surfaces.is_a?(Hash) && surfaces.keys == FIELDS &&
    surfaces.values.all? { |rows| rows.is_a?(Array) && rows.all? { |row| row.nil? || row.is_a?(String) } }
end

def valid_fixture_pagination?(pagination)
  pagination.is_a?(Hash) && pagination.keys == FIELDS &&
    pagination.values.all? { |count| count.is_a?(Integer) && count >= 0 }
end

def collect_markers(pull_request, matches, findings)
  malformed = 0
  pull_request.fetch("surfaces").each do |surface, texts|
    texts.compact.each do |text|
      exact_html_markers(text).each { |marker| matches << marker_row(pull_request, surface, marker) }
      blocks = review_finding_blocks(text)
      malformed += 1 if review_finding_fence_candidate?(text) && blocks.empty?
      blocks.each do |raw|
        malformed += parse_review_findings(raw, pull_request, surface, matches, findings)
      end
    end
  end
  malformed
end

def exact_html_markers(text)
  alternatives = HTML_MARKERS.map { |marker| Regexp.escape(marker) }.join("|")
  text.scan(/<!-- (?<marker>#{alternatives})\n.*?\n-->/m).map(&:first)
end

def review_finding_blocks(text)
  text.scan(/^```json[ \t]+review-findings\n(.*?)^```\s*$/m).flatten
end

def review_finding_fence_candidate?(text)
  text.match?(/^```json[ \t]+review-findings(?:\s|$)/)
end

def marker_row(pull_request, surface, marker)
  {
    "pr_url" => pull_request.fetch("url"),
    "source_kind" => SOURCE_KINDS.fetch(surface),
    "marker" => marker
  }
end

def parse_review_findings(raw, pull_request, surface, matches, findings)
  document = JSON.parse(raw)
  return 1 unless valid_review_document?(document, pull_request)

  matches << marker_row(pull_request, surface, REVIEW_SCHEMA)
  document.fetch("review_findings").each do |finding|
    findings << {
      "pr_url" => pull_request.fetch("url"),
      "source_kind" => SOURCE_KINDS.fetch(surface),
      "severity" => finding.fetch("severity")
    }
  end
  0
rescue JSON::ParserError
  1
end

def valid_review_document?(document, pull_request)
  failures = ValidateReviewFindings.validate_document(document, "review-finding-v0")
  return false unless failures.empty?

  document.fetch("review_findings").all? do |finding|
    valid_finding_target?(finding.fetch("target"), pull_request)
  end
end

def valid_finding_target?(target, pull_request)
  return false unless target["repo"]&.casecmp?(pull_request.fetch("repository"))

  target["pr"] == pull_request.fetch("number")
end

def per_pr_evidence(pull_request)
  surfaces = pull_request.fetch("surfaces")
  pagination = pull_request.fetch("pagination_requests")
  {
    "pr_url" => pull_request.fetch("url"),
    "surface_row_counts" => FIELDS.to_h { |field| [field, surfaces.fetch(field).length] },
    "pagination_requests" => FIELDS.to_h { |field| [field, pagination.fetch(field)] },
    "pagination_complete" => pull_request.fetch("pagination_complete", true),
    "surface_digest_sha256" => Digest::SHA256.hexdigest(JSON.generate(surfaces))
  }
end

def build_projection(collection, archived_collector_sha256:)
  matches = []
  findings = []
  malformed = collection.fetch("pull_requests").sum do |pr|
    collect_markers(pr, matches, findings)
  end
  evidence = collection.fetch("pull_requests").map { |pr| per_pr_evidence(pr) }
  surface_counts = FIELDS.to_h do |field|
    [field, evidence.sum { |row| row.dig("surface_row_counts", field) }]
  end
  pagination_counts = FIELDS.to_h do |field|
    [field, evidence.sum { |row| row.dig("pagination_requests", field) }]
  end
  scope_urls = evidence.map { |row| row.fetch("pr_url") }

  {
    "captured_at" => collection.fetch("captured_at"),
    "scope_pr_count" => collection.fetch("pull_requests").length,
    "fields" => FIELDS,
    "collection_provenance" => {
      "collector_contract" => COLLECTOR_CONTRACT,
      "capture_collector_sha256" => collection.fetch("capture_collector_sha256"),
      "archived_collector_sha256" => archived_collector_sha256,
      "query_evidence_sha256" => collection.fetch("query_evidence_sha256"),
      "response_evidence_sha256" => collection.fetch("response_evidence_sha256"),
      "review_finding_validator_sha256" => sha256_file(REVIEW_VALIDATOR_PATH),
      "scope_pr_url_set_sha256" => canonical_url_set_sha256(scope_urls),
      "graphql_requests" => collection.fetch("graphql_requests"),
      "surface_row_counts" => surface_counts,
      "pagination_requests" => pagination_counts,
      "pagination_complete" => collection.fetch("pagination_complete"),
      "per_pr_evidence" => evidence
    },
    "exact_markers" => MARKERS,
    "matching_markers" => matches.uniq.sort_by { |row| row.values_at("pr_url", "source_kind", "marker") },
    "severity_findings" => findings.sort_by { |row| row.values_at("pr_url", "source_kind", "severity") },
    "malformed_severity_candidates" => malformed,
    "search_errors" => collection.fetch("search_errors")
  }
end

def canonical_url_set_sha256(urls)
  Digest::SHA256.hexdigest(JSON.generate(urls.sort))
end

def fixture_collection(fixture, collector_sha256)
  canonical = JSON.generate(fixture)
  {
    "captured_at" => fixture.fetch("captured_at"),
    "graphql_requests" => fixture.fetch("graphql_requests"),
    "pagination_complete" => fixture.fetch("pagination_complete"),
    "capture_collector_sha256" => collector_sha256,
    "query_evidence_sha256" => Digest::SHA256.hexdigest(
      JSON.generate(fixture.fetch("pull_requests").map { |pr| pr.values_at("repository", "number") })
    ),
    "response_evidence_sha256" => Digest::SHA256.hexdigest(canonical),
    "search_errors" => [],
    "pull_requests" => fixture.fetch("pull_requests").map { |pr| pr.merge("pagination_complete" => true) }
  }
end

def live_collection(source, collector_sha256)
  pull_requests = source.fetch("github").fetch("pull_requests")
  query_digest = Digest::SHA256.new
  response_digest = Digest::SHA256.new
  graphql_requests = 0
  errors = []
  collected = []

  pull_requests.group_by { |pr| pr.fetch("repository") }.each do |repository, prs|
    owner, name = repository.split("/", 2)
    prs.each_slice(5) do |slice|
      query = marker_query(owner, name, slice)
      query_digest.update(query)
      graphql_requests += 1
      stdout, stderr, status = Open3.capture3("gh", "api", "graphql", "-f", "query=#{query}")
      unless status.success?
        errors << "graphql_error:#{repository}"
        warn stderr
        next
      end
      response_digest.update(stdout)
      data = graphql_repository_data(stdout, repository, errors)
      next unless data

      slice.each do |pr|
        collected_pr = collect_live_pr(pr, data["pr#{pr.fetch('number')}"], response_digest, errors)
        collected << collected_pr if collected_pr
      end
    end
  end

  {
    "captured_at" => Time.now.utc.iso8601,
    "graphql_requests" => graphql_requests,
    "pagination_complete" => errors.empty?,
    "capture_collector_sha256" => collector_sha256,
    "query_evidence_sha256" => query_digest.hexdigest,
    "response_evidence_sha256" => response_digest.hexdigest,
    "search_errors" => errors.sort,
    "pull_requests" => collected
  }
end

def graphql_repository_data(raw_response, repository, errors)
  response = JSON.parse(raw_response)
  if response["errors"].is_a?(Array) && response["errors"].any?
    errors << "graphql_response_error:#{repository}"
    return nil
  end

  data = response.dig("data", "repository")
  return data if data.is_a?(Hash)

  errors << "graphql_repository_missing:#{repository}"
  nil
rescue JSON::ParserError
  errors << "graphql_response_invalid:#{repository}"
  nil
end

def marker_query(owner, name, slice)
  selections = slice.map do |pr|
    <<~GRAPHQL
      pr#{pr.fetch('number')}: pullRequest(number: #{pr.fetch('number')}) {
        url
        body
        comments(first: 100) { pageInfo { hasNextPage } nodes { body } }
        reviews(first: 100) { pageInfo { hasNextPage } nodes { body } }
        reviewThreads(first: 100) {
          pageInfo { hasNextPage }
          nodes { comments(first: 100) { pageInfo { hasNextPage } nodes { body } } }
        }
      }
    GRAPHQL
  end.join("\n")
  <<~GRAPHQL
    query {
      repository(owner: #{owner.to_json}, name: #{name.to_json}) {
        #{selections}
      }
    }
  GRAPHQL
end

def collect_live_pr(pull_request, node, response_digest, errors)
  unless node
    errors << "missing_pr:#{pull_request.fetch('url')}"
    return nil
  end
  unless valid_live_pr_node?(node)
    errors << "invalid_graphql_shape:#{pull_request.fetch('url')}"
    return nil
  end

  surfaces = {
    "body" => [node["body"]],
    "comments" => node.dig("comments", "nodes").to_a.map { |row| row["body"] },
    "reviews" => node.dig("reviews", "nodes").to_a.map { |row| row["body"] },
    "review_thread_comments" => node.dig("reviewThreads", "nodes").to_a.flat_map do |thread|
      thread.dig("comments", "nodes").to_a.map { |row| row["body"] }
    end
  }
  pagination = FIELDS.to_h { |field| [field, 0] }
  context = { surfaces: surfaces, pagination: pagination, response_digest: response_digest, errors: errors }
  paginate_live_surfaces(pull_request, node, context)
  {
    "repository" => pull_request.fetch("repository"),
    "number" => pull_request.fetch("number"),
    "url" => pull_request.fetch("url"),
    "surfaces" => surfaces,
    "pagination_requests" => pagination,
    "pagination_complete" => errors.none? { |error| error.end_with?(pull_request.fetch("url")) }
  }
end

def valid_live_pr_node?(node)
  return false unless node.is_a?(Hash) && node.key?("body")
  return false unless %w[comments reviews reviewThreads].all? { |name| valid_connection?(node[name]) }

  node.dig("reviewThreads", "nodes").all? { |thread| valid_connection?(thread["comments"]) }
end

def valid_connection?(connection)
  connection.is_a?(Hash) && connection["nodes"].is_a?(Array) &&
    [true, false].include?(connection.dig("pageInfo", "hasNextPage"))
end

def paginate_live_surfaces(pull_request, node, context)
  repository = pull_request.fetch("repository")
  number = pull_request.fetch("number")
  if node.dig("comments", "pageInfo", "hasNextPage")
    context.fetch(:pagination)["comments"] += 1
    replace_paginated_surface(
      pull_request, "comments", "repos/#{repository}/issues/#{number}/comments?per_page=100", context
    )
  end
  if node.dig("reviews", "pageInfo", "hasNextPage")
    context.fetch(:pagination)["reviews"] += 1
    replace_paginated_surface(
      pull_request, "reviews", "repos/#{repository}/pulls/#{number}/reviews?per_page=100", context
    )
  end
  threads_truncated = node.dig("reviewThreads", "pageInfo", "hasNextPage") ||
                      node.dig("reviewThreads", "nodes").to_a.any? do |thread|
                        thread.dig("comments", "pageInfo", "hasNextPage")
                      end
  return unless threads_truncated

  context.fetch(:pagination)["review_thread_comments"] += 1
  replace_paginated_surface(
    pull_request,
    "review_thread_comments",
    "repos/#{repository}/pulls/#{number}/comments?per_page=100",
    context
  )
end

def replace_paginated_surface(pull_request, field, endpoint, context)
  bodies, error = paginated_bodies(endpoint, context.fetch(:response_digest))
  if bodies
    context.fetch(:surfaces)[field] = bodies
  else
    context.fetch(:errors) << "#{field}_error:#{pull_request.fetch('url')}"
    warn error
  end
end

def projection_from_document(document)
  document.dig("github", "structured_marker_scan") || document
end

def valid_projection?(projection, archived_collector_sha256, expected_pr_urls: nil)
  keys = %w[
    captured_at collection_provenance exact_markers fields malformed_severity_candidates
    matching_markers scope_pr_count search_errors severity_findings
  ]
  return false unless projection.is_a?(Hash) && projection.keys.sort == keys.sort
  return false unless projection["fields"] == FIELDS && projection["exact_markers"] == MARKERS
  return false unless projection["malformed_severity_candidates"].zero? && projection["search_errors"] == []

  provenance = projection["collection_provenance"]
  return false unless valid_provenance?(provenance, projection["scope_pr_count"], archived_collector_sha256)

  allowed_urls = provenance.fetch("per_pr_evidence").map { |row| row.fetch("pr_url") }
  return false unless expected_pr_urls.nil? || exact_url_set?(allowed_urls, expected_pr_urls)

  projection.fetch("matching_markers").all? { |row| valid_marker_row?(row, allowed_urls) } &&
    projection.fetch("severity_findings").all? { |row| valid_finding_row?(row, allowed_urls) }
end

def valid_provenance?(provenance, scope_count, archived_collector_sha256)
  keys = %w[
    archived_collector_sha256 capture_collector_sha256 collector_contract graphql_requests
    pagination_complete pagination_requests per_pr_evidence query_evidence_sha256
    response_evidence_sha256 review_finding_validator_sha256 scope_pr_url_set_sha256 surface_row_counts
  ]
  return false unless provenance.is_a?(Hash) && provenance.keys.sort == keys.sort
  return false unless valid_provenance_header?(provenance, archived_collector_sha256)

  evidence = provenance["per_pr_evidence"]
  valid_provenance_evidence?(provenance, evidence, scope_count)
end

def valid_provenance_header?(provenance, archived_collector_sha256)
  digests = %w[
    capture_collector_sha256 query_evidence_sha256 response_evidence_sha256
    review_finding_validator_sha256 scope_pr_url_set_sha256
  ]
  provenance["collector_contract"] == COLLECTOR_CONTRACT &&
    provenance["archived_collector_sha256"] == archived_collector_sha256 &&
    provenance["capture_collector_sha256"] == provenance["archived_collector_sha256"] &&
    digests.all? { |key| SHA256_PATTERN.match?(provenance[key].to_s) } &&
    provenance["review_finding_validator_sha256"] == sha256_file(REVIEW_VALIDATOR_PATH) &&
    provenance["graphql_requests"].is_a?(Integer) && provenance["graphql_requests"].positive? &&
    provenance["pagination_complete"] == true
end

def valid_provenance_evidence?(provenance, evidence, scope_count)
  return false unless evidence.is_a?(Array) && evidence.length == scope_count
  return false unless evidence.all? { |row| valid_per_pr_evidence?(row) }

  urls = evidence.map { |row| row.fetch("pr_url") }
  return false unless urls.uniq.length == urls.length
  return false unless provenance["scope_pr_url_set_sha256"] == canonical_url_set_sha256(urls)

  aggregate_evidence?(provenance, evidence, scope_count)
end

def exact_url_set?(actual, expected)
  actual.length == actual.uniq.length && expected.length == expected.uniq.length && actual.sort == expected.sort
end

def valid_per_pr_evidence?(row)
  keys = %w[pagination_complete pagination_requests pr_url surface_digest_sha256 surface_row_counts]
  row.is_a?(Hash) && row.keys.sort == keys.sort && row["pagination_complete"] == true &&
    row["pr_url"].is_a?(String) && SHA256_PATTERN.match?(row["surface_digest_sha256"].to_s) &&
    valid_count_hash?(row["surface_row_counts"]) && valid_count_hash?(row["pagination_requests"])
end

def valid_count_hash?(value)
  value.is_a?(Hash) && value.keys == FIELDS &&
    value.values.all? { |count| count.is_a?(Integer) && count >= 0 }
end

def aggregate_evidence?(provenance, evidence, scope_count)
  expected_rows = FIELDS.to_h do |field|
    [field, evidence.sum { |row| row.dig("surface_row_counts", field) }]
  end
  expected_pagination = FIELDS.to_h do |field|
    [field, evidence.sum { |row| row.dig("pagination_requests", field) }]
  end
  provenance["surface_row_counts"] == expected_rows &&
    provenance["pagination_requests"] == expected_pagination && expected_rows["body"] == scope_count
end

def valid_marker_row?(row, allowed_urls)
  row.is_a?(Hash) && row.keys.sort == %w[marker pr_url source_kind] &&
    allowed_urls.include?(row["pr_url"]) && SOURCE_KINDS.value?(row["source_kind"]) &&
    MARKERS.include?(row["marker"])
end

def valid_finding_row?(row, allowed_urls)
  row.is_a?(Hash) && row.keys.sort == %w[pr_url severity source_kind] &&
    allowed_urls.include?(row["pr_url"]) && SOURCE_KINDS.value?(row["source_kind"]) &&
    SEVERITIES.include?(row["severity"])
end

def write_projection(path, projection)
  File.write(path, "#{JSON.pretty_generate(projection)}\n")
end

collector_sha256 = sha256_file(__FILE__)
mode = ARGV.shift
case mode
when "fixture"
  abort "usage: #{$PROGRAM_NAME} fixture FIXTURE_JSON OUTPUT_JSON" unless ARGV.length == 2
  fixture = JSON.parse(File.read(ARGV.fetch(0)))
  abort "fixture schema is invalid" unless valid_fixture?(fixture)
  collection = fixture_collection(fixture, collector_sha256)
  projection = build_projection(collection, archived_collector_sha256: collector_sha256)
  write_projection(ARGV.fetch(1), projection)
  abort "pagination is incomplete" unless fixture.fetch("pagination_complete")
  abort "malformed severity candidate" unless projection.fetch("malformed_severity_candidates").zero?
  abort "fixture projection failed validation" unless valid_projection?(projection, collector_sha256)
when "live"
  abort "usage: #{$PROGRAM_NAME} live SOURCE_JSON OUTPUT_JSON" unless ARGV.length == 2
  source = JSON.parse(File.read(ARGV.fetch(0)))
  collection = live_collection(source, collector_sha256)
  projection = build_projection(collection, archived_collector_sha256: collector_sha256)
  write_projection(ARGV.fetch(1), projection)
  expected_urls = source.fetch("github").fetch("pull_requests").map { |pr| pr.fetch("url") }
  unless valid_projection?(projection, collector_sha256, expected_pr_urls: expected_urls)
    abort "live collection is incomplete or malformed"
  end
when "validate"
  abort "usage: #{$PROGRAM_NAME} validate PROJECTION_OR_SOURCE_JSON" unless ARGV.length == 1
  document = JSON.parse(File.read(ARGV.fetch(0)))
  projection = projection_from_document(document)
  expected_urls = document.dig("github", "pull_requests")&.map { |pr| pr.fetch("url") }
  unless valid_projection?(projection, collector_sha256, expected_pr_urls: expected_urls)
    abort "marker projection failed validation"
  end
  puts "MARKER_PROJECTION_OK"
when "graphql-fixture"
  abort "usage: #{$PROGRAM_NAME} graphql-fixture RESPONSE_JSON REPOSITORY" unless ARGV.length == 2
  errors = []
  data = graphql_repository_data(File.read(ARGV.fetch(0)), ARGV.fetch(1), errors)
  valid_nodes = data.is_a?(Hash) && data.values.all? { |node| valid_live_pr_node?(node) }
  abort "GraphQL response failed closed: #{errors.join(',')}" unless errors.empty? && valid_nodes
  puts "GRAPHQL_RESPONSE_OK"
else
  abort "usage: #{$PROGRAM_NAME} (fixture|live|validate|graphql-fixture) ..."
end
