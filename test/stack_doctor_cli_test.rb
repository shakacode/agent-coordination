# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"

class StackDoctorCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "agent-coord")
  CLEAN_ENV = {
    "AGENT_COORD_API_TOKEN" => nil,
    "AGENT_COORD_API_URL" => nil,
    "AGENT_COORD_BACKEND" => nil,
    "AGENT_COORD_STATE_ROOT" => nil,
    "AGENT_COORD_STATUS_STATE_ROOT" => nil
  }.freeze

  def test_shallow_stack_report_uses_uniform_healthy_contract
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      result = run_doctor("--stack-json", "--state-root", state_root)

      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal %w[checks component schema_version status], report.keys.sort
      assert_equal 1, report.fetch("schema_version")
      assert_equal "agent-coordination", report.fetch("component")
      assert_equal "healthy", report.fetch("status")
      check_ids = report.fetch("checks").map { |entry| entry.fetch("id") }.sort
      assert_equal %w[backend.readability cli.version resources.deep], check_ids
      assert_uniform_checks(report.fetch("checks"))
      assert_equal "skipped", check(report, "resources.deep").fetch("status")
    end
  end

  def test_deep_stack_report_collects_resource_evidence
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      write_json(state_root, "claims/demo/example/1.json", "schema_version" => 1)

      result = run_doctor("--stack-json", "--deep", "--state-root", state_root)

      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      resource_check = check(report, "resources.deep")
      assert_equal "healthy", report.fetch("status")
      assert_equal "healthy", resource_check.fetch("status")
      assert_equal "deep", resource_check.dig("details", "mode")
      assert_equal %w[archive batches claims events heartbeats], resource_check.dig("details", "prefixes").sort
    end
  end

  def test_deep_stack_report_fails_for_malformed_resource_evidence
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      broken_path = File.join(state_root, "heartbeats", "broken.json")
      FileUtils.mkdir_p(File.dirname(broken_path))
      File.write(broken_path, "{")

      result = run_doctor("--stack-json", "--deep", "--state-root", state_root)

      assert_equal 2, result.fetch(:status).exitstatus, result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      resource_check = check(report, "resources.deep")
      assert_equal "failed", report.fetch("status")
      assert_equal "failed", resource_check.fetch("status")
      assert_includes resource_check.dig("details", "error"), "state unreadable"
      assert_kind_of String, resource_check.fetch("guidance")
    end
  end

  def test_missing_explicit_root_is_failed_read_only_report_and_wins_backend_precedence
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      missing_root = File.join(root, "missing")
      fallback_root = File.join(root, "fallback")
      FileUtils.mkdir_p(fallback_root)

      result = run_doctor(
        "--stack-json", "--deep", "--state-root", missing_root,
        env: {
          "AGENT_COORD_API_URL" => "https://coordination.invalid",
          "AGENT_COORD_API_TOKEN" => "secret",
          "AGENT_COORD_STATUS_STATE_ROOT" => fallback_root
        }
      )

      assert_equal 2, result.fetch(:status).exitstatus, result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      backend_check = check(report, "backend.readability")
      assert_equal "failed", report.fetch("status")
      assert_equal "failed", backend_check.fetch("status")
      assert_equal "local", backend_check.dig("details", "backend")
      assert_equal missing_root, backend_check.dig("details", "state_root")
      assert_includes backend_check.dig("details", "error"), "state root does not exist"
      assert_equal "skipped", check(report, "resources.deep").fetch("status")
      refute_path_exists missing_root
    end
  end

  def test_stack_report_uses_exit_64_for_usage_errors
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      result = run_doctor("--stack-json", "--state-root", state_root, "--not-an-option")

      assert_equal 64, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stdout)
      assert_includes result.fetch(:stderr), "invalid option: --not-an-option"
    end
  end

  def test_stack_report_requires_one_direct_backend_selector
    result = run_doctor("--stack-json")

    assert_equal 64, result.fetch(:status).exitstatus
    assert_empty result.fetch(:stdout)
    assert_includes(
      result.fetch(:stderr),
      "doctor --stack-json requires exactly one of --state-root, --api-url, or --backend"
    )
  end

  def test_abbreviated_stack_json_requires_a_direct_backend_selector
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      result = run_doctor(
        "--stack-j",
        env: {
          "AGENT_COORD_STATE_ROOT" => state_root,
          "XDG_CONFIG_HOME" => File.join(state_root, "config")
        }
      )

      assert_equal 64, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stdout)
      assert_includes(
        result.fetch(:stderr),
        "doctor --stack-json requires exactly one of --state-root, --api-url, or --backend"
      )
    end
  end

  def test_abbreviated_stack_json_accepts_one_direct_backend_selector
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      result = run_doctor("--stack-j", "--state-root", state_root)

      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "healthy", report.fetch("status")
      assert_equal state_root, check(report, "backend.readability").dig("details", "state_root")
    end
  end

  def test_abbreviated_stack_json_rejects_conflicting_backend_selectors
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      result = run_doctor(
        "--stack-j",
        "--state-root", state_root,
        "--api-url", "http://127.0.0.1:9",
        "--backend", "example/coordination"
      )

      assert_equal 64, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stdout)
      assert_includes(
        result.fetch(:stderr),
        "doctor --stack-json requires exactly one of --state-root, --api-url, or --backend"
      )
    end
  end

  def test_option_parser_selector_abbreviations_preserve_stack_cardinality
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      valid = run_doctor("--stack-json", "--state-r", state_root)

      assert_equal 0, valid.fetch(:status).exitstatus, valid.fetch(:stderr)
      assert_equal "healthy", JSON.parse(valid.fetch(:stdout)).fetch("status")

      [
        ["abbreviated API URL", "--api-u", "http://127.0.0.1:9"],
        ["abbreviated legacy backend", "--back", "example/coordination"]
      ].each do |label, selector, value|
        result = run_doctor("--stack-json", "--state-root", state_root, selector, value)

        assert_equal 64, result.fetch(:status).exitstatus, label
        assert_empty result.fetch(:stdout), label
        assert_includes result.fetch(:stderr), "requires exactly one of", label
      end

      repeated = run_doctor("--stack-json", "--state-r", state_root, "--state-r", state_root)
      assert_equal 64, repeated.fetch(:status).exitstatus
      assert_empty repeated.fetch(:stdout)
    end
  end

  def test_stack_report_rejects_every_conflicting_backend_selector_combination
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      cases = {
        "state root and API URL" => ["--state-root", state_root, "--api-url", "http://127.0.0.1:9"],
        "state root and legacy backend" => ["--state-root", state_root, "--backend", "example/coordination"],
        "API URL and legacy backend" => ["--api-url", "http://127.0.0.1:9", "--backend", "example/coordination"],
        "repeated state root selector" => ["--state-root", state_root, "--state-root", state_root],
        "all three selectors" => [
          "--state-root", state_root,
          "--api-url", "http://127.0.0.1:9",
          "--backend", "example/coordination"
        ]
      }

      cases.each do |label, selectors|
        result = run_doctor("--stack-json", *selectors)

        assert_equal 64, result.fetch(:status).exitstatus, label
        assert_empty result.fetch(:stdout), label
        assert_includes(
          result.fetch(:stderr),
          "doctor --stack-json requires exactly one of --state-root, --api-url, or --backend",
          label
        )
      end
    end
  end

  def test_stack_selector_detection_does_not_count_an_option_name_used_as_a_value
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      result = run_doctor(
        "--stack-json", "--state-root", "--api-url",
        env: { "XDG_CONFIG_HOME" => File.join(root, "config") }
      )

      assert_equal 2, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "failed", report.fetch("status")
      assert_equal "--api-url", check(report, "backend.readability").dig("details", "state_root")
    end
  end

  def test_stack_doctor_suppresses_split_brain_advisory_but_human_doctor_preserves_it
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      state_root = File.join(root, "state")
      config_home = File.join(root, "config")
      env_file = File.join(config_home, "agent-coord", "env")
      FileUtils.mkdir_p(state_root)
      FileUtils.mkdir_p(File.dirname(env_file))
      File.write(env_file, "AGENT_COORD_API_URL=https://coordination.example\n")
      env = { "XDG_CONFIG_HOME" => config_home }

      stack_result = run_doctor("--stack-json", "--state-root", state_root, env: env)
      human_result = run_doctor("--state-root", state_root, env: env)

      assert_equal 0, stack_result.fetch(:status).exitstatus, stack_result.fetch(:stderr)
      assert_empty stack_result.fetch(:stderr)
      assert_equal 0, human_result.fetch(:status).exitstatus, human_result.fetch(:stderr)
      assert_includes human_result.fetch(:stderr), "split-brain configuration"
      assert_includes human_result.fetch(:stderr), env_file
    end
  end

  def test_stack_report_uses_exit_64_for_invalid_doctor_prefix
    result = run_doctor(
      "--stack-json", "--api-url", "http://127.0.0.1:9", "--doctor-prefix", "../secret",
      env: { "AGENT_COORD_API_TOKEN" => "test-token" }
    )

    assert_equal 64, result.fetch(:status).exitstatus
    assert_empty result.fetch(:stdout)
    assert_includes result.fetch(:stderr), "unsafe state path"
  end

  def test_stack_json_token_used_as_an_option_value_does_not_enable_stack_output
    result = run_doctor("--state-root", "--stack-json")

    assert_equal 2, result.fetch(:status).exitstatus
    assert_empty result.fetch(:stdout)
    assert_includes result.fetch(:stderr), "state root does not exist"
  end

  def test_stack_contract_rejects_implicit_root_without_creating_it
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      state_home = File.join(root, "state")
      expected_root = File.join(state_home, "agent-coordination")
      result = run_doctor(
        "--stack-json",
        env: {
          "XDG_STATE_HOME" => state_home,
          "XDG_CONFIG_HOME" => File.join(root, "config"),
          "HOME" => File.join(root, "home")
        }
      )

      assert_equal 64, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_empty result.fetch(:stdout)
      assert_includes result.fetch(:stderr), "requires exactly one of"
      refute_path_exists expected_root
      refute_path_exists state_home
    end
  end

  def test_missing_configured_root_does_not_fall_through_to_status_root
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      missing_root = File.join(root, "configured-missing")
      fallback_root = File.join(root, "status-root")
      FileUtils.mkdir_p(fallback_root)
      result = run_doctor(
        "--stack-json", "--state-root", missing_root,
        env: {
          "AGENT_COORD_STATE_ROOT" => missing_root,
          "AGENT_COORD_STATUS_STATE_ROOT" => fallback_root,
          "XDG_CONFIG_HOME" => File.join(root, "config")
        }
      )

      assert_equal 2, result.fetch(:status).exitstatus, result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      backend_check = check(report, "backend.readability")
      assert_equal "failed", report.fetch("status")
      assert_equal missing_root, backend_check.dig("details", "state_root")
      refute_path_exists missing_root
    end
  end

  def test_legacy_doctor_text_and_json_remain_unchanged
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      text_result = run_doctor("--state-root", state_root)
      json_result = run_doctor("--json", "--state-root", state_root)

      assert_equal 0, text_result.fetch(:status).exitstatus, text_result.fetch(:stderr)
      assert_equal legacy_doctor_text(state_root), text_result.fetch(:stdout)
      assert_equal 0, json_result.fetch(:status).exitstatus, json_result.fetch(:stderr)
      assert_equal(
        {
          "version" => "0.1.0",
          "backend" => "local",
          "backend_repo" => nil,
          "backend_url" => nil,
          "state_root" => state_root,
          "deep" => false,
          "status" => "ok"
        },
        JSON.parse(json_result.fetch(:stdout))
      )
    end
  end

  def test_unknown_http_resource_evidence_is_degraded
    with_http_backend do |api_url|
      result = run_doctor(
        "--stack-json", "--deep", "--api-url", api_url,
        env: { "AGENT_COORD_API_TOKEN" => "test-token" }
      )

      assert_equal 1, result.fetch(:status).exitstatus, result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      resource_check = check(report, "resources.deep")
      assert_equal "degraded", report.fetch("status")
      assert_equal "degraded", resource_check.fetch("status")
      assert_equal "unsupported", resource_check.dig("details", "resource_checks", "events")
      assert_equal "unsupported", resource_check.dig("details", "resource_checks", "archive")
      assert_kind_of String, resource_check.fetch("guidance")
    end
  end

  def test_custom_archive_prefix_unsupported_by_older_backend_is_degraded
    with_http_backend do |api_url|
      result = run_doctor(
        "--stack-json", "--deep", "--doctor-prefix", "archive", "--api-url", api_url,
        env: { "AGENT_COORD_API_TOKEN" => "test-token" }
      )

      assert_equal 1, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "degraded", report.fetch("status")
      assert_equal "healthy", check(report, "backend.readability").fetch("status")
      resource_check = check(report, "resources.deep")
      assert_equal "degraded", resource_check.fetch("status")
      assert_equal "unsupported", resource_check.dig("details", "resource_checks", "archive")
      assert_includes resource_check.dig("details", "notes", "archive"), "not supported"
    end
  end

  def test_deep_scoped_forbidden_evidence_is_degraded_not_backend_failure
    responses = lambda do |target|
      if target.include?("prefix=heartbeats")
        [403, { "error" => "forbidden" }]
      else
        http_response(target)
      end
    end

    with_http_backend(responses:) do |api_url|
      result = run_doctor(
        "--stack-json", "--deep", "--doctor-prefix", "heartbeats", "--api-url", api_url,
        env: { "AGENT_COORD_API_TOKEN" => "test-token" }
      )

      assert_equal 1, result.fetch(:status).exitstatus, result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "degraded", report.fetch("status")
      assert_equal "healthy", check(report, "backend.readability").fetch("status")
      resource_check = check(report, "resources.deep")
      assert_equal "degraded", resource_check.fetch("status")
      assert_equal "forbidden", resource_check.dig("details", "resource_checks", "heartbeats")
    end
  end

  def test_malformed_http_resource_evidence_fails_resource_check_not_backend_check
    responses = lambda do |target|
      if target.include?("prefix=heartbeats")
        [200, { "entries" => "not-an-array" }]
      else
        http_response(target)
      end
    end

    with_http_backend(responses:) do |api_url|
      result = run_doctor(
        "--stack-json", "--deep", "--api-url", api_url,
        env: { "AGENT_COORD_API_TOKEN" => "test-token" }
      )

      assert_equal 2, result.fetch(:status).exitstatus, result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "failed", report.fetch("status")
      assert_equal "healthy", check(report, "backend.readability").fetch("status")
      resource_check = check(report, "resources.deep")
      assert_equal "failed", resource_check.fetch("status")
      assert_includes resource_check.dig("details", "error"), "malformed response"
      backend_check_count = report.fetch("checks").count { |entry| entry.fetch("id") == "backend.readability" }
      assert_equal 1, backend_check_count
    end
  end

  def test_stack_report_maps_backend_configuration_failure_to_valid_contract
    result = run_doctor(
      "--stack-json", "--api-url", "https://coordination.invalid",
      env: {
        "AGENT_COORD_API_TOKEN" => nil,
        "XDG_STATE_HOME" => nil,
        "HOME" => nil
      }
    )

    assert_equal 2, result.fetch(:status).exitstatus, result.fetch(:stderr)
    assert_empty result.fetch(:stderr)
    report = JSON.parse(result.fetch(:stdout))
    assert_equal "failed", report.fetch("status")
    backend_check = check(report, "backend.readability")
    assert_equal "failed", backend_check.fetch("status")
    assert_includes backend_check.dig("details", "error"), "AGENT_COORD_API_TOKEN is required"
    assert_equal "skipped", check(report, "resources.deep").fetch("status")
  end

  private

  def legacy_doctor_text(state_root)
    missing_backend = nil
    <<~TEXT
      agent-coord doctor
      version: 0.1.0
      backend: local
      backend_repo: #{missing_backend}
      state_root: #{state_root}
      mode: lightweight
      status: ok
    TEXT
  end

  def run_doctor(*, env: {})
    stdout, stderr, status = Open3.capture3(
      CLEAN_ENV.merge(env),
      RbConfig.ruby,
      BIN,
      "doctor",
      *
    )
    { stdout: stdout, stderr: stderr, status: status }
  end

  def with_http_backend(responses: method(:http_response))
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        socket = server.accept
        target = socket.gets.to_s.split.fetch(1)
        while (line = socket.gets)
          break if line == "\r\n"
        end
        status, body = responses.call(target)
        payload = JSON.generate(body)
        socket.write(
          "HTTP/1.1 #{status} #{status == 200 ? 'OK' : 'Error'}\r\n" \
          "Content-Type: application/json\r\n" \
          "Content-Length: #{payload.bytesize}\r\n" \
          "Connection: close\r\n\r\n#{payload}"
        )
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr.fetch(1)}"
  ensure
    server&.close
    thread&.join(1)
  end

  def http_response(target)
    return [200, {}] if target == "/v1/health"
    return [404, {}] if target == "/v1/whoami"
    return [400, { "error" => "invalid_prefix" }] if target.include?("prefix=events")
    return [404, { "error" => "route_not_found" }] if target.include?("prefix=archive")

    [200, { "entries" => [] }]
  end

  def write_json(root, path, payload)
    full_path = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, "#{JSON.pretty_generate(payload)}\n")
  end

  def assert_uniform_checks(checks)
    checks.each do |entry|
      assert_equal %w[details guidance id status summary], entry.keys.sort
      assert_kind_of String, entry.fetch("id")
      assert_includes %w[healthy degraded failed skipped], entry.fetch("status")
      assert_kind_of String, entry.fetch("summary")
      assert_kind_of Hash, entry.fetch("details")
      assert(entry["guidance"].nil? || entry["guidance"].is_a?(String))
    end
  end

  def check(report, id)
    report.fetch("checks").find { |entry| entry.fetch("id") == id }.tap do |entry|
      refute_nil entry, "missing check #{id}"
    end
  end
end
