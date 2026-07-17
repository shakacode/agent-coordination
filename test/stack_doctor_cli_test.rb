# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "webrick"

module StackDoctorTestFixtures
  FAKE_GITHUB = <<~'RUBY'
    #!/usr/bin/env ruby
    require "base64"
    require "json"

    command = ARGV.join(" ")
    File.open(ENV.fetch("GH_LOG"), "a") { |file| file.puts(command) }
    case command
    when "auth status", /\Arepo view /
      exit 0
    when %r{\Aapi repos/example/coordination/git/trees/state\?recursive=1\z}
      puts JSON.generate(
        "tree" => [
          { "path" => "claims", "type" => "tree" },
          { "path" => "heartbeats", "type" => "tree" },
          { "path" => "heartbeats/unrequested.json", "type" => "blob" }
        ]
      )
    when %r{\Aapi repos/example/coordination/contents/heartbeats/unrequested\.json\?ref=state\z}
      puts JSON.generate("content" => Base64.strict_encode64("{"), "sha" => "broken")
    else
      warn "unexpected gh command: #{command}"
      exit 1
    end
  RUBY

  def self.write_fake_github(fake_bin)
    path = File.join(fake_bin, "gh")
    File.write(path, FAKE_GITHUB)
    FileUtils.chmod(0o755, path)
  end
end

module StackDoctorCliTestHarness
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "agent-coord")
  CLEAN_ENV = {
    "AGENT_COORD_API_TOKEN" => nil,
    "AGENT_COORD_API_URL" => nil,
    "AGENT_COORD_BACKEND" => nil,
    "AGENT_COORD_ENV_FILE" => nil,
    "AGENT_COORD_MACHINE_ID" => nil,
    "AGENT_COORD_SESSION_ID" => nil,
    "AGENT_COORD_STATE_ROOT" => nil,
    "AGENT_COORD_STATUS_STATE_ROOT" => nil,
    "CODEX_THREAD_ID" => nil
  }.freeze

  def run_doctor(*, env: {})
    stdout, stderr, status = Open3.capture3(CLEAN_ENV.merge(env), RbConfig.ruby, BIN, "doctor", *)
    { stdout:, stderr:, status: }
  end

  def check(report, id)
    report.fetch("checks").find { |entry| entry.fetch("id") == id }.tap do |entry|
      refute_nil entry, "missing check #{id}"
    end
  end
end

class LocalStoreReadabilityStackDoctorTest < Minitest::Test
  include StackDoctorCliTestHarness

  def test_default_and_custom_deep_checks_fail_for_unreadable_prefix_without_mutation
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      claims = File.join(state_root, "claims")
      FileUtils.mkdir_p(claims)
      FileUtils.chmod(0o000, claims)
      skip "filesystem permissions are not enforced for this user" if File.readable?(claims) || File.executable?(claims)

      begin
        cases = {
          "default" => [],
          "custom" => ["--doctor-prefix", "claims"]
        }
        cases.each do |label, extra|
          result = run_doctor("--stack-json", "--deep", "--state-root", state_root, *extra)
          assert_unreadable_prefix_failure(result, label)
        end
        assert_equal 0o000, File.stat(claims).mode & 0o777
        assert_equal ["claims"], Dir.children(state_root)
      ensure
        FileUtils.chmod(0o755, claims)
      end
    end
  end

  def test_default_and_custom_deep_checks_fail_for_nested_unreadable_directory_without_mutation
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      nested = File.join(state_root, "claims", "org")
      record = File.join(nested, "record.json")
      content = "#{JSON.generate('schema_version' => 1)}\n"
      FileUtils.mkdir_p(nested)
      File.binwrite(record, content)
      FileUtils.chmod(0o000, nested)
      skip "filesystem permissions are not enforced for this user" if File.readable?(nested) || File.executable?(nested)

      begin
        {
          "default" => [],
          "custom" => ["--doctor-prefix", "claims"]
        }.each do |label, extra|
          result = run_doctor("--stack-json", "--deep", "--state-root", state_root, *extra)
          assert_unreadable_prefix_failure(result, label)
        end
        assert_equal 0o000, File.stat(nested).mode & 0o777
      ensure
        FileUtils.chmod(0o755, nested)
      end

      assert_equal content, File.binread(record)
      assert_equal ["record.json"], Dir.children(nested)
    end
  end

  def test_default_and_custom_deep_checks_fail_closed_for_nested_symlink_directory
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      state_root = File.join(root, "state")
      outside = File.join(root, "outside")
      record = File.join(outside, "record.json")
      FileUtils.mkdir_p([File.join(state_root, "claims"), outside])
      File.write(record, "#{JSON.generate('schema_version' => 1)}\n")
      link = File.join(state_root, "claims", "org")
      File.symlink(outside, link)

      {
        "default" => [],
        "custom" => ["--doctor-prefix", "claims"]
      }.each do |label, extra|
        result = run_doctor("--stack-json", "--deep", "--state-root", state_root, *extra)
        assert_equal 2, result.fetch(:status).exitstatus, label
        assert_empty result.fetch(:stderr), label
        report = JSON.parse(result.fetch(:stdout))
        resource_check = check(report, "resources.deep")
        assert_equal "failed", report.fetch("status"), label
        assert_equal "healthy", check(report, "backend.readability").fetch("status"), label
        assert_equal "failed", resource_check.fetch("status"), label
        assert_includes resource_check.dig("details", "error"), "claims/org", label
        assert_includes resource_check.dig("details", "error"), "symlink", label
      end

      assert File.symlink?(link)
      assert_equal File.realpath(outside), File.realpath(link)
      assert_equal "#{JSON.generate('schema_version' => 1)}\n", File.read(record)
    end
  end

  def test_deep_check_explicitly_rejects_requested_directory_prefix_symlink
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      state_root = File.join(root, "state")
      outside = File.join(root, "outside")
      FileUtils.mkdir_p([File.join(state_root, "claims"), outside])
      link = File.join(state_root, "claims", "org")
      File.symlink(outside, link)

      result = run_doctor(
        "--stack-json", "--deep", "--state-root", state_root,
        "--doctor-prefix", "claims/org"
      )

      assert_equal 2, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      resource_check = check(report, "resources.deep")
      assert_equal "failed", resource_check.fetch("status")
      assert_includes resource_check.dig("details", "error"), "claims/org is a symlink"
      assert File.symlink?(link)
      assert_empty Dir.children(outside)
    end
  end

  def test_explicit_state_root_symlink_is_trusted_for_status_and_deep_doctor
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      target = File.join(root, "actual-state")
      state_root = File.join(root, "configured-state")
      FileUtils.mkdir_p(target)
      File.symlink(target, state_root)

      stdout, stderr, status = Open3.capture3(
        CLEAN_ENV.merge("XDG_CONFIG_HOME" => File.join(root, "missing-config")),
        RbConfig.ruby,
        BIN,
        "status",
        "--state-root",
        state_root
      )
      assert_equal 0, status.exitstatus
      assert_empty stderr
      assert_includes stdout, "claims\n- none"

      assert_deep_doctor_through_root_symlink(state_root)

      assert File.symlink?(state_root)
      assert_empty Dir.children(target)
    end
  end

  def test_custom_direct_record_fails_closed_for_symlink_leaf_without_reading_outside_root
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      state_root = File.join(root, "state")
      record_directory = File.join(state_root, "claims", "org", "repo")
      outside = File.join(root, "outside.json")
      outside_content = "#{JSON.generate('schema_version' => 1, 'outside' => true)}\n"
      FileUtils.mkdir_p(record_directory)
      File.write(outside, outside_content)
      record = File.join(record_directory, "1.json")
      File.symlink(outside, record)

      result = run_doctor(
        "--stack-json", "--deep", "--state-root", state_root,
        "--doctor-prefix", "claims/org/repo/1.json"
      )

      assert_equal 2, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "failed", report.fetch("status")
      assert_equal "healthy", check(report, "backend.readability").fetch("status")
      resource_check = check(report, "resources.deep")
      assert_equal "failed", resource_check.fetch("status")
      assert_includes resource_check.dig("details", "error"), "claims/org/repo/1.json"
      assert_includes resource_check.dig("details", "error"), "symlink"
      assert File.symlink?(record)
      assert_equal outside_content, File.read(outside)
    end
  end

  def test_custom_direct_record_fails_closed_for_intermediate_symlink_without_reading_outside_root
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      state_root = File.join(root, "state")
      outside = File.join(root, "outside")
      outside_record = File.join(outside, "repo", "1.json")
      outside_content = "#{JSON.generate('schema_version' => 1, 'outside' => true)}\n"
      FileUtils.mkdir_p([File.join(state_root, "claims"), File.dirname(outside_record)])
      File.write(outside_record, outside_content)
      link = File.join(state_root, "claims", "org")
      File.symlink(outside, link)

      result = run_doctor(
        "--stack-json", "--deep", "--state-root", state_root,
        "--doctor-prefix", "claims/org/repo/1.json"
      )

      assert_equal 2, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "failed", report.fetch("status")
      assert_equal "healthy", check(report, "backend.readability").fetch("status")
      resource_check = check(report, "resources.deep")
      assert_equal "failed", resource_check.fetch("status")
      assert_includes resource_check.dig("details", "error"), "claims/org"
      assert_includes resource_check.dig("details", "error"), "symlink"
      assert File.symlink?(link)
      assert_equal outside_content, File.read(outside_record)
    end
  end

  def test_custom_missing_direct_record_preserves_missing_resource_semantics_without_mutation
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      record_directory = File.join(state_root, "claims", "org", "repo")
      FileUtils.mkdir_p(record_directory)
      before = Dir.children(record_directory)
      prefix = "claims/org/repo/1.json"

      result = run_doctor(
        "--stack-json", "--deep", "--state-root", state_root,
        "--doctor-prefix", prefix
      )

      assert_equal 1, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "degraded", report.fetch("status")
      assert_equal "healthy", check(report, "backend.readability").fetch("status")
      resource_check = check(report, "resources.deep")
      assert_equal "degraded", resource_check.fetch("status")
      assert_equal "missing", resource_check.dig("details", "resource_checks", prefix)
      assert_includes resource_check.dig("details", "notes", prefix), "does not exist"
      assert_equal before, Dir.children(record_directory)
    end
  end

  def test_custom_direct_record_reads_regular_json_without_mutation
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      prefix = "claims/org/repo/1.json"
      record = File.join(state_root, prefix)
      content = "#{JSON.generate('schema_version' => 1)}\n"
      FileUtils.mkdir_p(File.dirname(record))
      File.write(record, content)
      mode = File.stat(record).mode & 0o777

      result = run_doctor(
        "--stack-json", "--deep", "--state-root", state_root,
        "--doctor-prefix", prefix
      )

      assert_equal 0, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "healthy", report.fetch("status")
      resource_check = check(report, "resources.deep")
      assert_equal "healthy", resource_check.fetch("status")
      assert_equal "ok", resource_check.dig("details", "resource_checks", prefix)
      assert_equal content, File.read(record)
      assert_equal mode, File.stat(record).mode & 0o777
    end
  end

  def test_nested_custom_prefix_reports_other_top_level_families_as_unprobed
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      prefix = "claims/org/repo/1.json"
      record = File.join(state_root, prefix)
      FileUtils.mkdir_p(File.dirname(record))
      File.write(record, "#{JSON.generate('schema_version' => 1)}\n")

      result = run_doctor(
        "--stack-json", "--deep", "--state-root", state_root,
        "--doctor-prefix", prefix
      )

      assert_equal 0, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stderr)
      resource_check = check(JSON.parse(result.fetch(:stdout)), "resources.deep")
      assert_equal [prefix], resource_check.dig("details", "prefixes")
      assert_equal %w[heartbeats batches events archive],
                   resource_check.dig("details", "unprobed_prefixes")
    end
  end

  def test_legacy_doctor_preserves_broader_custom_family_behavior
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      result = run_doctor(
        "--deep", "--state-root", state_root,
        "--doctor-prefix", "cliams/org",
        env: { "XDG_CONFIG_HOME" => File.join(state_root, "missing-config") }
      )

      assert_equal 0, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stderr)
      assert_includes result.fetch(:stdout), "doctor_prefix: cliams/org"
      assert_empty Dir.children(state_root)
    end
  end

  def test_custom_deep_check_fails_when_requested_prefix_is_not_a_directory
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      custom_prefix = File.join(state_root, "claims", "org")
      FileUtils.mkdir_p(File.dirname(custom_prefix))
      File.write(custom_prefix, "unchanged")

      result = run_doctor(
        "--stack-json", "--deep", "--state-root", state_root, "--doctor-prefix", "claims/org"
      )

      assert_equal 2, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "failed", report.fetch("status")
      assert_equal "healthy", check(report, "backend.readability").fetch("status")
      resource_check = check(report, "resources.deep")
      assert_equal "failed", resource_check.fetch("status")
      assert_equal ["claims/org"], resource_check.dig("details", "prefixes")
      assert_includes resource_check.dig("details", "error"), "claims/org is not a directory"
      assert_kind_of String, resource_check.fetch("guidance")
      assert_equal "unchanged", File.read(custom_prefix)
    end
  end

  def test_stack_report_rejects_unknown_doctor_prefix_family_before_every_backend_probe
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      fake_bin = File.join(state_root, "bin")
      github_log = File.join(state_root, "github.log")
      FileUtils.mkdir_p(fake_bin)
      StackDoctorTestFixtures.write_fake_github(fake_bin)

      with_recording_http_backend do |api_url, http_requests|
        unknown_prefix_cases(state_root, api_url, fake_bin, github_log).each do |label, (selector, env)|
          result = run_doctor(
            "--stack-json", "--deep", *selector, "--doctor-prefix", "cliams/org",
            env:
          )

          assert_equal 64, result.fetch(:status).exitstatus, label
          assert_empty result.fetch(:stdout), label
          assert_includes result.fetch(:stderr), "unknown doctor prefix family: cliams", label
        end

        assert_empty http_requests
        refute_path_exists github_log
      end
    end
  end

  def test_stack_report_rejects_malformed_below_family_doctor_prefixes
    prefixes = %w[
      claims/org/repo/1
      heartbeats/agent
      batches/batch
      events/batch/event
      archive/claims/org/repo/1
      archive/heartbeats/agent
    ]

    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      prefixes.each do |prefix|
        result = run_doctor(
          "--stack-json", "--deep", "--state-root", state_root, "--doctor-prefix", prefix
        )

        assert_equal 64, result.fetch(:status).exitstatus, prefix
        assert_empty result.fetch(:stdout), prefix
        assert_equal "invalid doctor prefix shape: #{prefix}\n", result.fetch(:stderr)
      end
      assert_empty Dir.children(state_root)
    end
  end

  def test_stack_report_rejects_malformed_prefix_before_every_backend_probe
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      fake_bin = File.join(state_root, "bin")
      github_log = File.join(state_root, "github.log")
      FileUtils.mkdir_p(fake_bin)
      StackDoctorTestFixtures.write_fake_github(fake_bin)

      with_recording_http_backend do |api_url, http_requests|
        unknown_prefix_cases(state_root, api_url, fake_bin, github_log).each do |label, (selector, env)|
          result = run_doctor(
            "--stack-json", "--deep", *selector, "--doctor-prefix", "claims/org/repo/1", env:
          )

          assert_equal 64, result.fetch(:status).exitstatus, label
          assert_empty result.fetch(:stdout), label
          assert_equal "invalid doctor prefix shape: claims/org/repo/1\n", result.fetch(:stderr), label
        end

        assert_empty http_requests
        refute_path_exists github_log
      end
    end
  end

  def test_stack_report_accepts_valid_family_directory_and_record_prefix_shapes
    prefixes = %w[
      claims
      claims/org/repo
      claims/org/repo/1.json
      heartbeats/agent.json
      events/batch
      archive/events/batch
      archive/events/batch/event.json
    ]

    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      prefixes.each do |prefix|
        result = run_doctor(
          "--stack-json", "--deep", "--state-root", state_root, "--doctor-prefix", prefix
        )

        assert_includes [0, 1], result.fetch(:status).exitstatus, prefix
        assert_empty result.fetch(:stderr), prefix
        report = JSON.parse(result.fetch(:stdout))
        assert_equal [prefix], check(report, "resources.deep").dig("details", "prefixes"), prefix
      end
      assert_empty Dir.children(state_root)
    end
  end

  private

  def assert_deep_doctor_through_root_symlink(state_root)
    {
      "default" => [],
      "custom" => ["--doctor-prefix", "claims"]
    }.each do |label, extra|
      result = run_doctor("--stack-json", "--deep", "--state-root", state_root, *extra)
      assert_equal 0, result.fetch(:status).exitstatus, label
      assert_empty result.fetch(:stderr), label
      report = JSON.parse(result.fetch(:stdout))
      assert_equal "healthy", report.fetch("status"), label
      assert_equal "healthy", check(report, "backend.readability").fetch("status"), label
      assert_equal "healthy", check(report, "resources.deep").fetch("status"), label
    end
  end

  def unknown_prefix_cases(state_root, api_url, fake_bin, github_log)
    {
      "local" => [["--state-root", state_root], {}],
      "HTTP" => [["--api-url", api_url], { "AGENT_COORD_API_TOKEN" => "test-token" }],
      "GitHub" => [
        ["--backend", "example/coordination"],
        { "GH_LOG" => github_log,
          "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR) }
      ]
    }
  end

  def with_recording_http_backend
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new { serve_recording_http_backend(server, requests) }
    yield "http://127.0.0.1:#{server.addr.fetch(1)}", requests
  ensure
    server&.close
    thread&.join(1)
  end

  def serve_recording_http_backend(server, requests)
    loop do
      socket = server.accept
      target = socket.gets.to_s.split.fetch(1)
      requests << target
      while (line = socket.gets)
        break if line == "\r\n"
      end
      payload = JSON.generate("entries" => [])
      socket.write(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}"
      )
      socket.close
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def assert_unreadable_prefix_failure(result, label)
    assert_equal 2, result.fetch(:status).exitstatus, label
    assert_empty result.fetch(:stderr), label
    report = JSON.parse(result.fetch(:stdout))
    assert_equal "failed", report.fetch("status"), label
    assert_equal "healthy", check(report, "backend.readability").fetch("status"), label
    resource_check = check(report, "resources.deep")
    assert_equal "failed", resource_check.fetch("status"), label
    assert_includes resource_check.dig("details", "error"), "claims", label
    assert_includes resource_check.dig("details", "error"), "not readable or searchable", label
    assert_kind_of String, resource_check.fetch("guidance"), label
    expected_prefixes = label == "custom" ? ["claims"] : %w[claims heartbeats batches events archive]
    assert_equal expected_prefixes, resource_check.dig("details", "prefixes"), label
    return unless label == "custom"

    assert_equal %w[heartbeats batches events archive], resource_check.dig("details", "unprobed_prefixes")
  end
end

class ExplicitBackendPrecedenceStackDoctorTest < Minitest::Test
  include StackDoctorCliTestHarness

  def test_explicit_github_stack_selector_ignores_ambient_local_and_http_backends
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      fake_bin = File.join(root, "bin")
      log_path = File.join(root, "gh.log")
      ambient_state = File.join(root, "ambient-state")
      FileUtils.mkdir_p([fake_bin, ambient_state])
      StackDoctorTestFixtures.write_fake_github(fake_bin)

      result = run_doctor(
        "--stack-json", "--backend", "example/coordination", "--ref", "state",
        env: {
          "AGENT_COORD_API_URL" => "http://127.0.0.1:9",
          "AGENT_COORD_API_TOKEN" => "ambient-token",
          "AGENT_COORD_STATE_ROOT" => ambient_state,
          "GH_LOG" => log_path,
          "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR)
        }
      )

      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      backend_check = check(report, "backend.readability")
      assert_equal "healthy", report.fetch("status")
      assert_equal "github", backend_check.dig("details", "backend")
      assert_equal "example/coordination", backend_check.dig("details", "backend_repo")
      assert_nil backend_check.dig("details", "backend_url")
      assert_nil backend_check.dig("details", "state_root")
      assert_includes File.readlines(log_path, chomp: true), "repo view example/coordination"
    end
  end

  def test_explicit_local_and_http_stack_selectors_do_not_report_ambient_github_backend
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      local = run_doctor(
        "--stack-json", "--state-root", state_root,
        env: { "AGENT_COORD_BACKEND" => "ambient/coordination" }
      )
      assert_stack_backend_details(local, "local", expected_status: 0, state_root: state_root)

      http = run_doctor(
        "--stack-json", "--api-url", "https://coordination.invalid",
        env: { "AGENT_COORD_BACKEND" => "ambient/coordination" }
      )
      assert_stack_backend_details(
        http, "http", expected_status: 2, backend_url: "https://coordination.invalid"
      )
    end
  end

  private

  def assert_stack_backend_details(result, backend, expected_status:, backend_url: nil, state_root: nil)
    assert_equal expected_status, result.fetch(:status).exitstatus, result.fetch(:stderr)
    assert_empty result.fetch(:stderr)
    details = check(JSON.parse(result.fetch(:stdout)), "backend.readability").fetch("details")
    assert_equal backend, details.fetch("backend")
    assert_nil details.fetch("backend_repo")
    if backend_url
      assert_equal backend_url, details.fetch("backend_url")
    else
      assert_nil details.fetch("backend_url")
    end
    if state_root
      assert_equal state_root, details.fetch("state_root")
    else
      assert_nil details.fetch("state_root")
    end
  end
end

class StackDoctorOutputModeCliTest < Minitest::Test
  include StackDoctorCliTestHarness

  def test_stack_report_rejects_legacy_json_output_flag
    [%w[--json --stack-json], %w[--stack-json --json]].each do |output_flags|
      Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
        result = run_doctor(*output_flags, "--state-root", state_root)

        assert_equal 64, result.fetch(:status).exitstatus, output_flags.join(" ")
        assert_empty result.fetch(:stdout), output_flags.join(" ")
        assert_equal "doctor --json and --stack-json are mutually exclusive\n", result.fetch(:stderr)
      end
    end
  end
end

class StackDoctorCliTest < Minitest::Test
  include StackDoctorCliTestHarness

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
      assert_equal %w[backend.readability cli.version identity.machine resources.deep], check_ids
      assert_uniform_checks(report.fetch("checks"))
      assert_equal "skipped", check(report, "resources.deep").fetch("status")
      assert_equal "skipped", check(report, "identity.machine").fetch("status")
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

  def test_invalid_option_before_abbreviated_stack_json_still_uses_exit_sixty_four
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      result = run_doctor("--bogus", "--stack-j", "--state-root", state_root)

      assert_equal 64, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stdout)
      assert_includes result.fetch(:stderr), "invalid option: --bogus"
    end
  end

  def test_ambiguous_option_prefix_does_not_hide_later_stack_json_abbreviation
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      result = run_doctor("--sta", "--stack-j", "--state-root", state_root)

      assert_equal 64, result.fetch(:status).exitstatus
      assert_empty result.fetch(:stdout)
      assert_includes result.fetch(:stderr), "ambiguous option: --sta"
    end
  end

  def test_stack_json_abbreviation_used_as_an_option_value_does_not_enable_stack_output
    result = run_doctor("--bogus", "--state-r", "--stack-j")

    assert_equal 1, result.fetch(:status).exitstatus
    assert_empty result.fetch(:stdout)
    assert_includes result.fetch(:stderr), "invalid option: --bogus"
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

  def test_stack_report_rejects_malformed_direct_github_backend_as_usage
    result = run_doctor("--stack-json", "--backend", "not-a-repo")

    assert_equal 64, result.fetch(:status).exitstatus
    assert_empty result.fetch(:stdout)
    assert_equal "invalid backend repo: not-a-repo\n", result.fetch(:stderr)
  end

  def test_stack_report_rejects_empty_direct_backend_selector_values
    cases = {
      "state root with equals" => ["--state-root="],
      "state root with separate value" => ["--state-root", ""],
      "API URL with equals" => ["--api-url="],
      "API URL with separate value" => ["--api-url", ""],
      "legacy backend with equals" => ["--backend="],
      "legacy backend with separate value" => ["--backend", ""],
      "abbreviated state root" => ["--state-r="],
      "abbreviated API URL" => ["--api-u="],
      "abbreviated legacy backend" => ["--back="]
    }

    cases.each do |label, selector|
      result = run_doctor("--stack-json", *selector)

      assert_equal 64, result.fetch(:status).exitstatus, label
      assert_empty result.fetch(:stdout), label
      assert_includes result.fetch(:stderr), "requires a non-empty value", label
    end
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

  def test_stack_doctor_suppresses_backend_selector_conflict_warning
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      result = run_doctor(
        "--stack-json", "--state-root", state_root,
        env: {
          "AGENT_COORD_API_URL" => "https://coordination.example",
          "AGENT_COORD_API_TOKEN" => "test-token"
        }
      )

      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_empty result.fetch(:stderr)
      assert_equal "healthy", JSON.parse(result.fetch(:stdout)).fetch("status")
    end
  end

  def test_run_doctor_does_not_inherit_ambient_coordination_env_file
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      state_root = File.join(root, "state")
      env_file = File.join(root, "ambient-env")
      FileUtils.mkdir_p(state_root)
      File.write(env_file, "AGENT_COORD_API_URL=https://coordination.example\n")

      with_parent_env("AGENT_COORD_ENV_FILE", env_file) do
        result = run_doctor(
          "--state-root", state_root,
          env: { "XDG_CONFIG_HOME" => File.join(root, "missing-config") }
        )

        assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
        assert_empty result.fetch(:stderr)
      end
    end
  end

  def test_stack_report_uses_exit_64_for_invalid_doctor_prefix_before_every_backend_probe
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      cases = {
        "local" => [["--state-root", state_root], {}],
        "HTTP" => [["--api-url", "http://127.0.0.1:9"], { "AGENT_COORD_API_TOKEN" => "test-token" }],
        "GitHub" => [["--backend", "example/coordination"], { "PATH" => "/nonexistent" }]
      }

      cases.each do |label, (selector, env)|
        result = run_doctor(
          "--stack-json", "--deep", *selector, "--doctor-prefix", "../secret",
          env:
        )

        assert_equal 64, result.fetch(:status).exitstatus, label
        assert_empty result.fetch(:stdout), label
        assert_includes result.fetch(:stderr), "unsafe state path", label
      end
    end
  end

  def test_stack_report_rejects_noncanonical_local_doctor_prefixes
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      ["", ".", "./claims", "claims/.", "claims/./nested", "/claims", "claims//nested"].each do |prefix|
        result = run_doctor(
          "--stack-json", "--deep", "--state-root", state_root, "--doctor-prefix", prefix
        )

        assert_equal 64, result.fetch(:status).exitstatus, prefix.inspect
        assert_empty result.fetch(:stdout), prefix.inspect
        assert_includes result.fetch(:stderr), "unsafe state path", prefix.inspect
      end
    end
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
      assert_equal %w[claims heartbeats batches events archive], resource_check.dig("details", "prefixes")
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
      assert_equal ["archive"], resource_check.dig("details", "prefixes")
      assert_equal %w[claims heartbeats batches events], resource_check.dig("details", "unprobed_prefixes")
      assert_equal "unsupported", resource_check.dig("details", "resource_checks", "archive")
      assert_includes resource_check.dig("details", "notes", "archive"), "not supported"
    end
  end

  def test_custom_local_prefix_probes_only_requested_read_only_scope
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      claims = File.join(state_root, "claims")
      heartbeats = File.join(state_root, "heartbeats")
      FileUtils.mkdir_p([claims, heartbeats])
      broken_heartbeat = File.join(heartbeats, "unrequested.json")
      File.write(broken_heartbeat, "{")
      before = Dir.glob(File.join(state_root, "**", "*"), File::FNM_DOTMATCH).sort

      begin
        FileUtils.chmod(0o444, broken_heartbeat)
        FileUtils.chmod(0o555, [claims, heartbeats, state_root])

        result = run_doctor(
          "--stack-json", "--deep", "--doctor-prefix", "claims", "--state-root", state_root
        )

        assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
        assert_empty result.fetch(:stderr)
        report = JSON.parse(result.fetch(:stdout))
        resource_check = check(report, "resources.deep")
        assert_equal "healthy", report.fetch("status")
        assert_equal "healthy", resource_check.fetch("status")
        assert_equal ["claims"], resource_check.dig("details", "prefixes")
        assert_equal %w[heartbeats batches events archive], resource_check.dig("details", "unprobed_prefixes")
        assert_equal({ "claims" => "ok" }, resource_check.dig("details", "resource_checks"))
        assert_equal before, Dir.glob(File.join(state_root, "**", "*"), File::FNM_DOTMATCH).sort
      ensure
        FileUtils.chmod_R(0o755, state_root)
      end
    end
  end

  def test_custom_github_prefix_does_not_read_unrequested_tree_blobs
    Dir.mktmpdir("agent-coord-stack-doctor") do |root|
      fake_bin = File.join(root, "bin")
      log_path = File.join(root, "gh.log")
      FileUtils.mkdir_p(fake_bin)
      StackDoctorTestFixtures.write_fake_github(fake_bin)

      result = run_doctor(
        "--stack-json", "--deep", "--doctor-prefix", "claims",
        "--backend", "example/coordination", "--ref", "state",
        env: {
          "GH_LOG" => log_path,
          "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR)
        }
      )

      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_empty result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      resource_check = check(report, "resources.deep")
      assert_equal "healthy", report.fetch("status")
      assert_equal ["claims"], resource_check.dig("details", "prefixes")
      assert_equal %w[heartbeats batches events archive], resource_check.dig("details", "unprobed_prefixes")
      assert_equal({ "claims" => "ok" }, resource_check.dig("details", "resource_checks"))
      gh_calls = File.readlines(log_path, chomp: true)
      assert(gh_calls.any? { |call| call.include?("git/trees/state?recursive=1") })
      refute(gh_calls.any? { |call| call.include?("contents/heartbeats/unrequested.json") })
    end
  end

  def test_stack_report_reads_healthy_read_only_local_state_without_mutating_layout
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      claim_directory = File.join(state_root, "claims", "demo")
      claim_path = File.join(claim_directory, "example.json")
      FileUtils.mkdir_p(claim_directory)
      File.write(claim_path, "#{JSON.generate('schema_version' => 1)}\n")
      before = Dir.glob(File.join(state_root, "**", "*"), File::FNM_DOTMATCH).sort

      begin
        FileUtils.chmod(0o444, claim_path)
        FileUtils.chmod(0o555, claim_directory)
        FileUtils.chmod(0o555, File.join(state_root, "claims"))
        FileUtils.chmod(0o555, state_root)

        shallow = run_doctor("--stack-json", "--state-root", state_root)
        deep = run_doctor("--stack-json", "--deep", "--state-root", state_root)
        legacy = run_doctor("--state-root", state_root)

        assert_equal 0, shallow.fetch(:status).exitstatus, shallow.fetch(:stderr)
        assert_equal "healthy", JSON.parse(shallow.fetch(:stdout)).fetch("status")
        assert_equal 0, deep.fetch(:status).exitstatus, deep.fetch(:stderr)
        assert_equal "healthy", JSON.parse(deep.fetch(:stdout)).fetch("status")
        assert_equal 2, legacy.fetch(:status).exitstatus unless File.writable?(state_root)
        assert_includes legacy.fetch(:stderr), "state root is not writable" unless File.writable?(state_root)
        assert_equal before, Dir.glob(File.join(state_root, "**", "*"), File::FNM_DOTMATCH).sort
      ensure
        FileUtils.chmod_R(0o755, state_root)
      end
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
    assert_equal "http", backend_check.dig("details", "backend")
    assert_equal "https://coordination.invalid", backend_check.dig("details", "backend_url")
    assert_includes backend_check.dig("details", "error"), "AGENT_COORD_API_TOKEN is required"
    refute backend_check.fetch("details").key?("error_class")
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

  def with_parent_env(name, value)
    original = ENV.fetch(name, nil)
    ENV[name] = value
    yield
  ensure
    original.nil? ? ENV.delete(name) : ENV[name] = original
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
end

class StackDoctorHttpBackendStub
  def initialize(responses)
    @responses = responses
    @server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    @server.mount_proc("/") do |_req, res|
      status, body = @responses.shift || [500, { "error" => "unexpected" }]
      res.status = status
      res.content_type = "application/json"
      res.body = JSON.generate(body)
    end
    @thread = Thread.new { @server.start }
  end

  def base_url = "http://127.0.0.1:#{@server.config[:Port]}"
  def shutdown = @server.shutdown && @thread.join
end

class MachineIdentityStackDoctorTest < Minitest::Test
  include StackDoctorCliTestHarness

  def test_deep_http_stack_doctor_fails_on_machine_identity_mismatch
    stub = StackDoctorHttpBackendStub.new(deep_http_responses(token_machine: "m1-codex"))
    result = run_doctor(
      "--stack-json", "--deep", "--api-url", stub.base_url,
      env: {
        "AGENT_COORD_API_TOKEN" => "tok",
        "AGENT_COORD_MACHINE_ID" => "m5",
        "CODEX_THREAD_ID" => "codex-thread-42"
      }
    )

    assert_equal 2, result.fetch(:status).exitstatus, result.fetch(:stderr)
    report = JSON.parse(result.fetch(:stdout))
    identity_check = check(report, "identity.machine")
    assert_equal "failed", report.fetch("status")
    assert_equal "failed", identity_check.fetch("status")
    assert_equal "healthy", check(report, "resources.deep").fetch("status")
    assert_equal "mismatch", identity_check.dig("details", "machine_match")
    assert_equal "m5", identity_check.dig("details", "machine_id")
    assert_equal "m1-codex", identity_check.dig("details", "token_machine")
    assert_equal "codex-thread-42", identity_check.dig("details", "session_id")
    assert_equal "codex_thread_id", identity_check.dig("details", "session_source")
    assert_includes identity_check.fetch("guidance"), "AGENT_COORD_MACHINE_ID"
  ensure
    stub&.shutdown
  end

  def test_deep_http_stack_doctor_reports_machine_identity_match
    stub = StackDoctorHttpBackendStub.new(deep_http_responses(token_machine: "m5"))
    result = run_doctor(
      "--stack-json", "--deep", "--api-url", stub.base_url,
      env: { "AGENT_COORD_API_TOKEN" => "tok", "AGENT_COORD_MACHINE_ID" => "m5" }
    )

    assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
    report = JSON.parse(result.fetch(:stdout))
    identity_check = check(report, "identity.machine")
    assert_equal "healthy", report.fetch("status")
    assert_equal "healthy", identity_check.fetch("status")
    assert_equal "match", identity_check.dig("details", "machine_match")
    assert_equal "m5", identity_check.dig("details", "token_machine")
    assert_nil identity_check.fetch("guidance")
  ensure
    stub&.shutdown
  end

  def test_deep_http_stack_doctor_without_environment_machine_skips_identity_verification
    stub = StackDoctorHttpBackendStub.new(deep_http_responses(token_machine: "m5"))
    result = run_doctor(
      "--stack-json", "--deep", "--api-url", stub.base_url,
      env: { "AGENT_COORD_API_TOKEN" => "tok" }
    )

    assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
    report = JSON.parse(result.fetch(:stdout))
    identity_check = check(report, "identity.machine")
    assert_equal "healthy", report.fetch("status")
    assert_equal "skipped", identity_check.fetch("status")
    assert_equal "unverified", identity_check.dig("details", "machine_match")
    assert_nil identity_check.dig("details", "machine_id")
    assert_equal "m5", identity_check.dig("details", "token_machine")
  ensure
    stub&.shutdown
  end

  def test_local_stack_doctor_reports_unverified_identity_without_token_machine
    Dir.mktmpdir("agent-coord-stack-doctor") do |state_root|
      result = run_doctor(
        "--stack-json", "--deep", "--state-root", state_root,
        env: { "AGENT_COORD_MACHINE_ID" => "m5" }
      )

      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      report = JSON.parse(result.fetch(:stdout))
      identity_check = check(report, "identity.machine")
      assert_equal "healthy", report.fetch("status")
      assert_equal "skipped", identity_check.fetch("status")
      assert_equal "unverified", identity_check.dig("details", "machine_match")
      assert_equal "m5", identity_check.dig("details", "machine_id")
      assert_nil identity_check.dig("details", "token_machine")
    end
  end

  private

  def deep_http_responses(token_machine:)
    [[200, { "status" => "ok" }]] +
      Array.new(5) { [200, { "entries" => [] }] } +
      [[200, { "machine" => token_machine, "read_prefixes" => ["*"], "write_prefixes" => ["*"] }]]
  end
end
