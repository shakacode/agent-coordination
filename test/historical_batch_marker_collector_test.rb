# frozen_string_literal: true

require "bundler"
require "base64"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class HistoricalBatchMarkerCollectorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ARCHIVED_COLLECTOR = File.join(
    ROOT,
    "docs/archive/reports/data/2026-07-18-historical-batch-baseline-marker-collector.rb"
  )
  LIVE_COLLECTOR = File.join(
    ROOT,
    "docs/archive/reports/data/historical-batch-marker-collector-v2.rb"
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

  EQUAL_CONTRACT_CONSTANTS = %w[SCHEMA].freeze
  NON_SHRINKING_CONTRACT_CONSTANTS = %w[
    SEVERITIES
    DISPOSITIONS
    VERIFICATION_STATUSES
    CURRENT_HEAD_STATES
    RISK_LENS_STATUSES
    COVERAGE_STATUSES
    INDEPENDENT_VALIDATION_STATUSES
    RECEIPT_TARGET_KINDS
    RECEIPT_SOURCES
  ].freeze
  # STRING_ARRAY_FIELDS is grouped with the required-field lists: adding a field here newly
  # constrains a previously-unconstrained finding field, so it must not grow either.
  NON_GROWING_CONTRACT_CONSTANTS = %w[
    REQUIRED_FINDING_FIELDS
    REQUIRED_VERIFICATION_FIELDS
    PROVENANCE_USAGE_FIELDS
    STRING_ARRAY_FIELDS
  ].freeze
  CONTRACT_CONSTANTS = (
    EQUAL_CONTRACT_CONSTANTS + NON_SHRINKING_CONTRACT_CONSTANTS + NON_GROWING_CONTRACT_CONSTANTS
  ).freeze

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
    _stdout, stderr, status = run_archived_collector("validate", SOURCE)

    assert status.success?, stderr
  end

  def test_validate_rejects_capture_collector_hash_mismatch
    source = JSON.parse(File.read(SOURCE))
    provenance = source.dig("github", "structured_marker_scan", "collection_provenance")
    provenance["capture_collector_sha256"] = "0" * 64

    Dir.mktmpdir("marker-projection-test") do |dir|
      path = File.join(dir, "source.json")
      File.write(path, JSON.generate(source))
      _stdout, stderr, status = run_archived_collector("validate", path)

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
    sources = contract_surface(REVIEW_VALIDATOR).fetch("RECEIPT_SOURCES")
    sources.each do |source|
      lenses = source == "autoreview" ? [risk_lens("correctness"), risk_lens("security")] : [risk_lens("release")]
      document = receipt_document(source: source, lenses: lenses)

      assert_collector_and_shared(document, expected: true)
    end

    invalid_autoreview = receipt_document(source: "autoreview", lenses: [risk_lens("correctness")])
    assert_collector_and_shared(invalid_autoreview, expected: false)
  end

  def test_severity_and_disposition_vocabulary_matches_shared_validator
    archived = contract_surface(REVIEW_VALIDATOR)
    document = severity_and_disposition_document(archived.fetch("SEVERITIES"), archived.fetch("DISPOSITIONS"))

    assert_collector_and_shared(document, expected: true)
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

  # Compares the declared contract surface (vocabularies, required-field lists) only, not
  # full behaviour: assert_collector_and_shared covers behavioural agreement separately.
  # Full behavioural equivalence is deliberately not asserted, since legitimate hardening
  # (e.g. UNKNOWN sentinel normalization) can narrow acceptance without drifting this surface.
  def test_installed_shared_validator_still_accepts_archived_contract_surface
    external = installed_shared_validator
    skip "agent-workflows shared validator is not installed" unless external

    drifts = contract_drifts(contract_surface(REVIEW_VALIDATOR), contract_surface(external))

    assert_empty drifts, drifts.join("\n")
  end

  def test_incomplete_pagination_is_rejected
    fixture = JSON.parse(File.read(FIXTURE))
    fixture["pagination_complete"] = false

    _projection, stderr, status = collect_fixture_result(fixture)

    refute status.success?
    assert_includes stderr, "pagination is incomplete"
  end

  def test_live_collection_normalizes_valid_utf8_from_graphql_and_rest_under_ascii_locale
    graphql_response = valid_live_graphql_response(comments_truncated: true)
    rest_response = [[{ "body" => "REST naïve" }]]

    projection, stdout, stderr, status = run_live_api(
      graphql_stdout: JSON.generate(graphql_response),
      rest_stdout: JSON.generate(rest_response)
    )

    assert status.success?, [stdout, stderr].reject(&:empty?).join("\n")
    assert_equal 1, projection.dig("collection_provenance", "surface_row_counts", "comments")
    assert_equal 1, projection.dig("collection_provenance", "pagination_requests", "comments")
    assert_equal true, projection.dig("collection_provenance", "pagination_complete")
  end

  def test_live_collection_scrubs_diagnostic_bytes_without_rewriting_payloads
    invalid_diagnostic = "gh failed: caf\xFF".b

    _projection, stdout, stderr, status = run_live_api(
      graphql_stdout: "",
      rest_stdout: "[]",
      graphql_stderr: invalid_diagnostic,
      graphql_status: 1
    )

    refute status.success?, stdout
    assert_predicate stderr, :valid_encoding?
    assert_includes stderr, "gh failed: caf�"
    assert_includes stderr, "live collection is incomplete or malformed"
  end

  def test_live_collection_ignores_malformed_stdout_when_graphql_command_fails
    projection, stdout, stderr, status = run_live_api(
      graphql_stdout: "unused caf\xFF".b,
      rest_stdout: "[]",
      graphql_stderr: "graphql failed",
      graphql_status: 1
    )

    refute status.success?, stdout
    refute_nil projection
    assert_equal ["graphql_error:example/alpha"], projection.fetch("search_errors")
    assert_includes stderr, "graphql failed"
    refute_includes stderr, "invalid byte sequence in UTF-8"
  end

  def test_live_collection_ignores_malformed_stdout_when_rest_command_fails
    projection, stdout, _stderr, status = run_live_api(
      graphql_stdout: JSON.generate(valid_live_graphql_response(comments_truncated: true)),
      rest_stdout: "unused caf\xFF".b,
      rest_status: 1
    )

    refute status.success?, stdout
    refute_nil projection
    assert_equal ["comments_error:https://github.com/example/alpha/pull/7"], projection.fetch("search_errors")
  end

  def test_live_collection_rejects_malformed_utf8_api_payload_without_scrubbing
    malformed_payload = JSON.generate(valid_live_graphql_response).b.sub(
      "GraphQL café".b,
      "GraphQL caf\xFF".b
    )

    projection, stdout, stderr, status = run_live_api(
      graphql_stdout: malformed_payload,
      rest_stdout: "[]"
    )

    refute status.success?, stdout
    assert_nil projection
    assert_match(/invalid byte sequence in UTF-8|JSON::ParserError|Encoding::InvalidByteSequenceError/, stderr)
  end

  def test_live_collection_rejects_malformed_utf8_in_ignored_graphql_field
    response = valid_live_graphql_response.merge("extensions" => { "ignored" => "café" })
    malformed_payload = JSON.generate(response).b.sub("café".b, "caf\xFF".b)

    projection, stdout, stderr, status = run_live_api(
      graphql_stdout: malformed_payload,
      rest_stdout: "[]"
    )

    refute status.success?, stdout
    assert_nil projection
    assert_match(/invalid byte sequence in UTF-8|JSON::ParserError|Encoding::InvalidByteSequenceError/, stderr)
  end

  def test_live_collection_rejects_malformed_json_api_payload
    projection, stdout, stderr, status = run_live_api(
      graphql_stdout: '{"data":',
      rest_stdout: "[]"
    )

    refute status.success?, stdout
    assert_equal ["graphql_response_invalid:example/alpha"], projection.fetch("search_errors")
    assert_includes stderr, "live collection is incomplete or malformed"
  end

  def test_live_collection_rejects_malformed_utf8_rest_payload_without_scrubbing
    malformed_payload = JSON.generate([[{ "body" => "REST naïve" }]]).b.sub(
      "REST naïve".b,
      "REST na\xFFve".b
    )

    projection, stdout, stderr, status = run_live_api(
      graphql_stdout: JSON.generate(valid_live_graphql_response(comments_truncated: true)),
      rest_stdout: malformed_payload
    )

    refute status.success?, stdout
    assert_nil projection
    assert_match(/invalid byte sequence in UTF-8|JSON::ParserError|Encoding::InvalidByteSequenceError/, stderr)
  end

  def test_live_collection_rejects_malformed_utf8_in_ignored_rest_field
    malformed_payload = JSON.generate([[{ "body" => nil, "ignored" => "café" }]]).b.sub(
      "café".b,
      "caf\xFF".b
    )

    projection, stdout, stderr, status = run_live_api(
      graphql_stdout: JSON.generate(valid_live_graphql_response(comments_truncated: true)),
      rest_stdout: malformed_payload
    )

    refute status.success?, stdout
    assert_nil projection
    assert_match(/invalid byte sequence in UTF-8|JSON::ParserError|Encoding::InvalidByteSequenceError/, stderr)
  end

  def test_live_collection_rejects_malformed_json_rest_payload
    projection, stdout, stderr, status = run_live_api(
      graphql_stdout: JSON.generate(valid_live_graphql_response(comments_truncated: true)),
      rest_stdout: '[[{"body":'
    )

    refute status.success?, stdout
    assert_nil projection
    assert_match(/JSON::ParserError/, stderr)
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

  def test_graphql_fixture_normalizes_valid_utf8_under_ascii_locale
    stdout, stderr, status = run_graphql_fixture(valid_live_graphql_response, ascii_locale: true)

    assert status.success?, stderr
    assert_equal "GRAPHQL_RESPONSE_OK\n", stdout
  end

  def test_graphql_fixture_rejects_malformed_utf8_without_scrubbing
    malformed_payload = JSON.generate(valid_live_graphql_response).b.sub(
      "GraphQL café".b,
      "GraphQL caf\xFF".b
    )

    stdout, stderr, status = run_graphql_fixture_payload(malformed_payload, ascii_locale: true)

    refute status.success?, stdout
    assert_empty stdout
    assert_equal "invalid byte sequence in UTF-8\n", stderr
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

  def severity_and_disposition_document(severities, dispositions)
    document = fixture_review_document(JSON.parse(File.read(FIXTURE)))
    template = document.fetch("review_findings").first
    findings = dispositions.each_with_index.map do |disposition, index|
      template.merge(
        "id" => "fixture-vocabulary-#{index}",
        "severity" => severities[index % severities.length],
        "disposition" => disposition
      )
    end
    document.merge("review_findings" => findings)
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

  def contract_surface(validator_path)
    script = <<~RUBY
      require "json"
      load ARGV[0]
      constants = #{CONTRACT_CONSTANTS.inspect}
      surface = constants.each_with_object({}) do |name, memo|
        next unless ValidateReviewFindings.const_defined?(name)

        memo[name] = ValidateReviewFindings.const_get(name)
      end
      puts JSON.generate(surface)
    RUBY
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(RbConfig.ruby, "-e", script, validator_path)
    end
    raise "failed to read contract surface from #{validator_path}: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def contract_drifts(archived, installed)
    CONTRACT_CONSTANTS.flat_map do |name|
      next [] unless archived.key?(name)
      next ["#{name}: missing from installed shared validator"] unless installed.key?(name)

      contract_constant_drift(name, archived.fetch(name), installed.fetch(name))
    end
  end

  def contract_constant_drift(name, archived_value, installed_value)
    if EQUAL_CONTRACT_CONSTANTS.include?(name)
      contract_equality_drift(name, archived_value, installed_value)
    elsif NON_SHRINKING_CONTRACT_CONSTANTS.include?(name)
      contract_shrinkage_drift(name, archived_value, installed_value)
    else
      contract_growth_drift(name, archived_value, installed_value)
    end
  end

  def contract_equality_drift(name, archived_value, installed_value)
    return [] if archived_value == installed_value

    ["#{name}: expected #{archived_value.inspect}, installed validator has #{installed_value.inspect}"]
  end

  def contract_shrinkage_drift(name, archived_value, installed_value)
    removed = Array(archived_value) - Array(installed_value)
    return [] if removed.empty?

    ["#{name}: installed validator removed #{removed.sort.inspect} from the allowed values"]
  end

  def contract_growth_drift(name, archived_value, installed_value)
    added = Array(installed_value) - Array(archived_value)
    return [] if added.empty?

    ["#{name}: installed validator added #{added.sort.inspect}, which the archived contract did not require"]
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
      run_archived_collector("validate", path)
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
      stdout, stderr, status = run_archived_collector("fixture", fixture_path, output_path)
      projection = File.exist?(output_path) ? JSON.parse(File.read(output_path)) : nil
      [projection, [stdout, stderr].reject(&:empty?).join("\n"), status]
    end
  end

  def run_archived_collector(*arguments)
    Bundler.with_unbundled_env do
      Open3.capture3(RbConfig.ruby, ARCHIVED_COLLECTOR, *arguments)
    end
  end

  def run_graphql_fixture(response, ascii_locale: false)
    run_graphql_fixture_payload(JSON.generate(response), ascii_locale: ascii_locale)
  end

  def run_graphql_fixture_payload(payload, ascii_locale: false)
    Dir.mktmpdir("graphql-marker-fixture") do |dir|
      path = File.join(dir, "response.json")
      File.binwrite(path, payload)
      environment = ascii_locale ? ascii_locale_environment(dir) : {}
      Bundler.with_unbundled_env do
        Open3.capture3(environment, RbConfig.ruby, LIVE_COLLECTOR, "graphql-fixture", path, "example/alpha")
      end
    end
  end

  def run_live_api(graphql_stdout:, rest_stdout:, graphql_stderr: "", graphql_status: 0, rest_status: 0)
    Dir.mktmpdir("historical-marker-live-api") do |dir|
      write_fake_gh(
        dir,
        graphql_stdout: graphql_stdout,
        rest_stdout: rest_stdout,
        graphql_stderr: graphql_stderr,
        statuses: { graphql: graphql_status, rest: rest_status }
      )
      source_path, output_path = write_live_source(dir)
      stdout, stderr, status = Bundler.with_unbundled_env do
        Open3.capture3(
          ascii_locale_environment(dir),
          RbConfig.ruby,
          LIVE_COLLECTOR,
          "live",
          source_path,
          output_path
        )
      end
      projection = JSON.parse(File.read(output_path)) if File.file?(output_path)
      [projection, stdout, stderr, status]
    end
  end

  def write_live_source(dir)
    source_path = File.join(dir, "source.json")
    output_path = File.join(dir, "projection.json")
    source = {
      "github" => {
        "pull_requests" => [
          {
            "repository" => "example/alpha",
            "number" => 7,
            "url" => "https://github.com/example/alpha/pull/7"
          }
        ]
      }
    }
    File.write(source_path, JSON.generate(source))
    [source_path, output_path]
  end

  def ascii_locale_environment(dir)
    {
      "LC_ALL" => "C",
      "LANG" => "C",
      "PATH" => [dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR)
    }
  end

  def valid_live_graphql_response(comments_truncated: false)
    {
      "data" => {
        "repository" => {
          "pr7" => {
            "url" => "https://github.com/example/alpha/pull/7",
            "body" => "GraphQL café",
            "comments" => { "pageInfo" => { "hasNextPage" => comments_truncated }, "nodes" => [] },
            "reviews" => { "pageInfo" => { "hasNextPage" => false }, "nodes" => [] },
            "reviewThreads" => { "pageInfo" => { "hasNextPage" => false }, "nodes" => [] }
          }
        }
      }
    }
  end

  def write_fake_gh(dir, graphql_stdout:, rest_stdout:, graphql_stderr:, statuses:)
    encoded_graphql = Base64.strict_encode64(graphql_stdout.b)
    encoded_rest = Base64.strict_encode64(rest_stdout.b)
    encoded_graphql_stderr = Base64.strict_encode64(graphql_stderr.b)
    script = <<~RUBY
      #!/usr/bin/env ruby
      require "base64"
      graphql = ARGV.include?("graphql")
      stdout = graphql ? #{encoded_graphql.dump} : #{encoded_rest.dump}
      stderr = graphql ? #{encoded_graphql_stderr.dump} : ""
      STDOUT.binmode
      STDERR.binmode
      STDOUT.write(Base64.strict_decode64(stdout))
      STDERR.write(Base64.strict_decode64(stderr)) unless stderr.empty?
      exit(graphql ? #{statuses.fetch(:graphql)} : #{statuses.fetch(:rest)})
    RUBY
    path = File.join(dir, "gh")
    File.write(path, script)
    File.chmod(0o755, path)
  end
end
