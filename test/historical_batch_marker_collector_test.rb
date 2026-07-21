# frozen_string_literal: true

require "bundler"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class HistoricalBatchMarkerCollectorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  COLLECTOR = File.join(
    ROOT,
    "docs/archive/reports/data/2026-07-18-historical-batch-baseline-marker-collector.rb"
  )
  REVIEW_VALIDATOR = File.join(
    ROOT,
    "docs/archive/reports/data/2026-07-18-historical-batch-review-finding-validator.rb.source"
  )
  SOURCE = File.join(
    ROOT,
    "docs/archive/reports/data/2026-07-18-historical-batch-baseline-source.json"
  )
  FIXTURE = File.join(ROOT, "test/fixtures/historical-batch-marker-surfaces.json")

  def test_offline_fixture_replay_is_deterministic_and_sanitized
    first = collect_fixture(JSON.parse(File.read(FIXTURE)))
    second = collect_fixture(JSON.parse(File.read(FIXTURE)))

    assert_equal first, second
    assert_equal 2, first.fetch("scope_pr_count")
    assert_equal %w[body comments reviews review_thread_comments], first.fetch("fields")
    assert_equal 4, first.fetch("matching_markers").length
    assert_equal(["P1"], first.fetch("severity_findings").map { |row| row.fetch("severity") })
    provenance = first.fetch("collection_provenance")
    assert_equal true, provenance.fetch("pagination_complete")
    assert_equal 1, provenance.dig("pagination_requests", "reviews")
    assert_equal 2, provenance.dig("surface_row_counts", "body")
    assert_equal 2, provenance.fetch("per_pr_evidence").length
    refute_includes JSON.generate(first), "synthetic fixture finding"
    refute_includes JSON.generate(first), "synthetic fixture marker"
  end

  def test_validate_accepts_frozen_projection
    _stdout, stderr, status = run_collector("validate", SOURCE)

    assert status.success?, stderr
  end

  def test_validate_rejects_capture_collector_hash_mismatch
    source = JSON.parse(File.read(SOURCE))
    provenance = source.dig("github", "structured_marker_scan", "collection_provenance")
    provenance["capture_collector_sha256"] = "0" * 64

    Dir.mktmpdir("marker-projection-test") do |dir|
      path = File.join(dir, "source.json")
      File.write(path, JSON.generate(source))
      _stdout, stderr, status = run_collector("validate", path)

      refute status.success?
      assert_includes stderr, "marker projection failed validation"
    end
  end

  def test_validate_rejects_duplicate_receipt_that_omits_same_count_pr
    source = JSON.parse(File.read(SOURCE))
    evidence = source.dig("github", "structured_marker_scan", "collection_provenance", "per_pr_evidence")
    retained = evidence.find { |row| row["pr_url"] == "https://github.com/shakacode/hichee/pull/9827" }
    omitted_index = evidence.index do |row|
      row["pr_url"] == "https://github.com/shakacode/react-on-rails-demo-flagship/pull/25"
    end
    evidence[omitted_index] = JSON.parse(JSON.generate(retained))

    _stdout, stderr, status = validate_document(source)

    refute status.success?
    assert_includes stderr, "marker projection failed validation"
  end

  def test_prose_marker_mentions_do_not_count
    fixture = JSON.parse(File.read(FIXTURE))
    fixture.fetch("pull_requests").first["surfaces"] = {
      "body" => ["A prose mention of review-finding-v0 is not an envelope."],
      "comments" => ["A prose mention of completed-batch-audit v1 is not an envelope."],
      "reviews" => ["A prose mention of codex-claim v1 is not an envelope."],
      "review_thread_comments" => ["A prose mention of post-merge-audit-finding v1 is not an envelope."]
    }

    projection = collect_fixture(fixture)

    assert_empty projection.fetch("matching_markers")
    assert_empty projection.fetch("severity_findings")
    assert_equal 0, projection.fetch("malformed_severity_candidates")
  end

  def test_incomplete_review_finding_is_rejected
    fixture = JSON.parse(File.read(FIXTURE))
    document = fixture_review_document(fixture)
    document.fetch("review_findings").first.delete("body")
    set_fixture_review_document(fixture, document)

    _projection, stderr, status = collect_fixture_result(fixture)

    refute status.success?
    assert_includes stderr, "malformed severity candidate"
  end

  def test_duplicate_review_finding_ids_are_rejected
    fixture = JSON.parse(File.read(FIXTURE))
    document = fixture_review_document(fixture)
    document.fetch("review_findings") << JSON.parse(JSON.generate(document.fetch("review_findings").first))
    set_fixture_review_document(fixture, document)

    _projection, stderr, status = collect_fixture_result(fixture)

    refute status.success?
    assert_includes stderr, "malformed severity candidate"
  end

  def test_info_review_finding_is_accepted
    fixture = JSON.parse(File.read(FIXTURE))
    document = fixture_review_document(fixture)
    document.fetch("review_findings").first["severity"] = "INFO"
    set_fixture_review_document(fixture, document)

    projection = collect_fixture(fixture)
    severities = projection.fetch("severity_findings").map { |row| row.fetch("severity") }

    assert_equal ["INFO"], severities
  end

  def test_valid_post_merge_audit_receipt_matches_shared_validator
    document = receipt_document(
      source: "post-merge-audit",
      lenses: [risk_lens("release-safety")],
      usage: {
        "input_tokens" => 120,
        "output_tokens" => 30,
        "cache_read_tokens" => 20,
        "total_tokens" => 150
      }
    )

    assert_collector_and_shared(document, expected: true)
  end

  def test_all_shared_receipt_sources_and_lens_rules_match
    sources = %w[
      autoreview adversarial-pr-review continuous-evaluation-loop post-merge-audit address-review
    ]
    sources.each do |source|
      lenses = source == "autoreview" ? [risk_lens("correctness"), risk_lens("security")] : [risk_lens("release")]
      document = receipt_document(source: source, lenses: lenses)

      assert_collector_and_shared(document, expected: true)
    end

    invalid_autoreview = receipt_document(source: "autoreview", lenses: [risk_lens("correctness")])
    assert_collector_and_shared(invalid_autoreview, expected: false)
  end

  def test_negative_or_incomplete_usage_matches_shared_validator
    negative = receipt_document(
      source: "autoreview",
      lenses: [risk_lens("correctness"), risk_lens("security")],
      usage: {
        "input_tokens" => -1,
        "output_tokens" => 1,
        "cache_read_tokens" => 0,
        "total_tokens" => 1
      }
    )
    assert_collector_and_shared(negative, expected: false)

    missing_counter = receipt_document(
      source: "autoreview",
      lenses: [risk_lens("correctness"), risk_lens("security")],
      usage: {
        "input_tokens" => 10,
        "output_tokens" => 2,
        "total_tokens" => 12
      }
    )
    assert_collector_and_shared(missing_counter, expected: false)
  end

  def test_usage_totals_and_unknown_sentinel_match_shared_validator
    low_total = receipt_document(
      source: "autoreview",
      lenses: [risk_lens("correctness"), risk_lens("security")],
      usage: {
        "input_tokens" => 10,
        "output_tokens" => 3,
        "cache_read_tokens" => "UNKNOWN",
        "total_tokens" => 12
      }
    )
    assert_collector_and_shared(low_total, expected: false)

    lowercase_unknown = receipt_document(
      source: "autoreview",
      lenses: [risk_lens("correctness"), risk_lens("security")]
    )
    lowercase_unknown.dig("review_receipt", "provenance")["model"] = "unknown"
    assert_collector_and_shared(lowercase_unknown, expected: false)
  end

  def test_archived_validator_matches_installed_shared_contract
    external = installed_shared_validator
    skip "agent-workflows shared validator is not installed" unless external

    assert_equal File.binread(external), File.binread(REVIEW_VALIDATOR)
  end

  def test_incomplete_pagination_is_rejected
    fixture = JSON.parse(File.read(FIXTURE))
    fixture["pagination_complete"] = false

    _projection, stderr, status = collect_fixture_result(fixture)

    refute status.success?
    assert_includes stderr, "pagination is incomplete"
  end

  def test_malformed_severity_candidate_is_rejected
    fixture = JSON.parse(File.read(FIXTURE))
    body = fixture.dig("pull_requests", 0, "surfaces", "body", 0)
    fixture.dig("pull_requests", 0, "surfaces", "body")[0] = body.sub('"P1"', '"P9"')

    _projection, stderr, status = collect_fixture_result(fixture)

    refute status.success?
    assert_includes stderr, "malformed severity candidate"
  end

  def test_unexpected_raw_surface_is_rejected
    fixture = JSON.parse(File.read(FIXTURE))
    fixture.dig("pull_requests", 0, "surfaces")["messages"] = ["synthetic"]

    _projection, stderr, status = collect_fixture_result(fixture)

    refute status.success?
    assert_includes stderr, "fixture schema is invalid"
  end

  def test_graphql_errors_fail_closed_even_with_partial_data
    response = {
      "data" => { "repository" => {} },
      "errors" => [{ "message" => "synthetic partial response" }]
    }

    _stdout, stderr, status = run_graphql_fixture(response)

    refute status.success?
    assert_includes stderr, "graphql_response_error:example/alpha"
  end

  def test_missing_graphql_connection_shape_fails_closed
    response = {
      "data" => {
        "repository" => {
          "pr7" => {
            "body" => nil,
            "comments" => { "pageInfo" => { "hasNextPage" => false }, "nodes" => [] },
            "reviews" => nil,
            "reviewThreads" => { "pageInfo" => { "hasNextPage" => false }, "nodes" => [] }
          }
        }
      }
    }

    _stdout, stderr, status = run_graphql_fixture(response)

    refute status.success?
    assert_includes stderr, "GraphQL response failed closed"
  end

  private

  def assert_collector_and_shared(document, expected:)
    fixture = JSON.parse(File.read(FIXTURE))
    set_fixture_review_document(fixture, document)
    _projection, collector_error, collector_status = collect_fixture_result(fixture)
    validators = [REVIEW_VALIDATOR, installed_shared_validator].compact.uniq

    validators.each do |validator|
      _stdout, validator_error, validator_status = run_schema_validator(document, validator)
      assert_equal expected, validator_status.success?, "#{validator}: #{validator_error}"
    end
    assert_equal expected, collector_status.success?, collector_error
  end

  def receipt_document(source:, lenses:, usage: :omitted)
    document = fixture_review_document(JSON.parse(File.read(FIXTURE)))
    finding = document.fetch("review_findings").first
    head_sha = "b" * 40
    finding.fetch("target")["head_sha"] = head_sha
    finding["independent_validation"] = {
      "status" => "confirmed",
      "validator" => "fixture-independent-reviewer",
      "evidence" => ["Synthetic differential validation evidence."]
    }
    provenance = {
      "engine" => "fixture-engine",
      "invocation" => "fixture review",
      "model" => "gpt-fixture",
      "effort" => "high"
    }
    provenance["usage"] = usage unless usage == :omitted
    document["review_receipt"] = {
      "source" => source,
      "target" => {
        "kind" => "committed",
        "base_ref" => "origin/main",
        "base_sha" => "a" * 40,
        "head_sha" => head_sha
      },
      "provenance" => provenance,
      "risk_lenses" => lenses,
      "coverage" => {
        "status" => "complete",
        "included_paths" => ["example.rb"],
        "excluded_paths" => [],
        "limitations" => []
      }
    }
    document
  end

  def risk_lens(name)
    {
      "name" => name,
      "status" => "applied",
      "reason" => "Synthetic differential contract coverage."
    }
  end

  def run_schema_validator(document, validator)
    Dir.mktmpdir("review-schema-test") do |dir|
      path = File.join(dir, "review.json")
      File.write(path, JSON.generate(document))
      Bundler.with_unbundled_env { Open3.capture3(RbConfig.ruby, validator, path) }
    end
  end

  def installed_shared_validator
    configured = ENV.fetch("AGENT_WORKFLOWS_REVIEW_VALIDATOR", nil)
    return configured if File.file?(configured.to_s)

    stdout, status = Open3.capture2("git", "-C", ROOT, "rev-parse", "--git-common-dir")
    return nil unless status.success?

    common_dir = File.expand_path(stdout.strip, ROOT)
    candidate = File.join(File.dirname(common_dir, 2), "agent-workflows", "bin", "validate-review-findings")
    File.file?(candidate) ? candidate : nil
  end

  def fixture_review_document(fixture)
    text = fixture.dig("pull_requests", 0, "surfaces", "body", 0)
    JSON.parse(text.match(/```json review-findings\n(.*?)\n```/m)[1])
  end

  def set_fixture_review_document(fixture, document)
    fixture.dig("pull_requests", 0, "surfaces", "body")[0] = [
      "```json review-findings",
      JSON.generate(document),
      "```"
    ].join("\n")
  end

  def validate_document(document)
    Dir.mktmpdir("marker-projection-test") do |dir|
      path = File.join(dir, "source.json")
      File.write(path, JSON.generate(document))
      run_collector("validate", path)
    end
  end

  def collect_fixture(fixture)
    projection, stderr, status = collect_fixture_result(fixture)
    assert status.success?, stderr
    projection
  end

  def collect_fixture_result(fixture)
    Dir.mktmpdir("marker-collector-test") do |dir|
      fixture_path = File.join(dir, "fixture.json")
      output_path = File.join(dir, "projection.json")
      File.write(fixture_path, JSON.pretty_generate(fixture))
      stdout, stderr, status = run_collector("fixture", fixture_path, output_path)
      projection = File.exist?(output_path) ? JSON.parse(File.read(output_path)) : nil
      [projection, [stdout, stderr].reject(&:empty?).join("\n"), status]
    end
  end

  def run_collector(*arguments)
    Bundler.with_unbundled_env do
      Open3.capture3(RbConfig.ruby, COLLECTOR, *arguments)
    end
  end

  def run_graphql_fixture(response)
    Dir.mktmpdir("graphql-marker-fixture") do |dir|
      path = File.join(dir, "response.json")
      File.write(path, JSON.generate(response))
      run_collector("graphql-fixture", path, "example/alpha")
    end
  end
end
