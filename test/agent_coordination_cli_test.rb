# frozen_string_literal: true

require "fileutils"
require "json"
require "json_schemer"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "shellwords"
require "stringio"
require "tmpdir"

class AgentCoordTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "agent-coord")
  HTTP_INTEGRATION_BIN = File.join(ROOT, "bin", "test-http-integration")
  LAUNCHD_HEARTBEAT_TEMPLATE = File.join(ROOT, "launchd", "com.shakacode.agent-coord-heartbeat.plist.example")
  SYSTEMD_TEMPLATE = File.join(ROOT, "systemd", "agent-coord-heartbeat.service.example")
  FAKE_SHASUM = <<~RUBY
    #!/usr/bin/env ruby
    warn "shasum should not be used by bin/test-http-integration"
    exit 127
  RUBY
  FAKE_BUNDLE = <<~RUBY
    #!/usr/bin/env ruby
    File.write(ENV.fetch("FAKE_BUNDLE_LOG"), ARGV.join(" "))
    exit Integer(ENV.fetch("FAKE_BUNDLE_EXIT", "0")) if ARGV == %w[exec ruby test/http_backend_integration_test.rb]

    warn "unexpected bundle command: \#{ARGV.join(" ")}"
    exit 1
  RUBY
  FAKE_NPX = <<~RUBY
    #!/usr/bin/env ruby
    require "json"

    def write_event(event)
      File.open(ENV.fetch("FAKE_NPX_LOG"), "a") { |file| file.puts(JSON.generate(event)) }
    end

    write_event(
      "argv" => ARGV,
      "pwd" => Dir.pwd,
      "wrangler_output_log" => ENV["WRANGLER_OUTPUT_LOG"],
      "xdg_config_home" => ENV["XDG_CONFIG_HOME"],
      "xdg_cache_home" => ENV["XDG_CACHE_HOME"],
      "wrangler_log_path" => ENV["WRANGLER_LOG_PATH"]
    )

    def persist_to_arg
      index = ARGV.index("--persist-to")
      index && ARGV.fetch(index + 1)
    end

    if ARGV[0, 5] == %w[wrangler d1 migrations apply agent-coord] &&
        ARGV.include?("--local") &&
        persist_to_arg
      exit 0
    elsif ARGV[0, 2] == %w[wrangler dev] &&
        ARGV.include?("--local") &&
        ARGV.include?("--port") &&
        ARGV.include?("8787") &&
        persist_to_arg
      require "socket"

      File.write(ENV.fetch("FAKE_WRANGLER_PID"), Process.pid.to_s)
      server = TCPServer.new("127.0.0.1", 8787)
      trap("TERM") do
        write_event("signal" => "TERM")
        File.write(ENV.fetch("FAKE_WRANGLER_STOPPED"), "1")
        server.close
        exit 0
      end

      loop do
        socket = server.accept
        while (line = socket.gets)
          break if line.chomp.empty?
        end
        socket.write "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        socket.close
      end
    elsif ARGV[0, 5] == %w[wrangler d1 execute agent-coord --local] &&
        persist_to_arg &&
        (index = ARGV.index("--command"))
      command = ARGV.fetch(index + 1)
      write_event("argv" => ARGV, "command" => command)
      exit 0 if command.match?(/\\b[0-9a-f]{64}\\b/) && !command.include?("integration-token-")
    end

    warn "unexpected npx command: \#{ARGV.join(" ")}"
    exit 1
  RUBY
  load BIN

  def setup
    @state_root = Dir.mktmpdir("agent-coord-test")
  end

  def teardown
    FileUtils.remove_entry(@state_root)
  end

  def test_help_lists_commands
    result = run_agent_coord("--help", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "claim"
    assert_includes result.stdout, "release"
    assert_includes result.stdout, "heartbeat"
    assert_includes result.stdout, "status"
    assert_includes result.stdout, "version"
    assert_includes result.stdout, "config"
    assert_includes result.stdout, "doctor"
    assert_includes result.stdout, "bootstrap"
    assert_includes result.stdout, "demo"
  end

  def test_demo_walks_claim_liveness_and_takeover_deterministically
    first = run_agent_coord("demo", state_root: nil)
    second = run_agent_coord("demo", state_root: nil)

    assert_equal 0, first.status.exitstatus, first.stderr
    assert_equal 0, second.status.exitstatus, second.stderr
    assert_equal first.stdout, second.stdout
    assert_empty first.stderr
    assert_includes first.stdout, "isolated local store — no remote writes"
    assert_includes first.stdout, "CLAIM_REFUSED"
    assert_includes first.stdout, "held by demo-alpha; heartbeat live"
    assert_includes first.stdout, "demo-alpha heartbeat stale"
    assert_includes first.stdout, "demo-alpha heartbeat dead"
    assert_includes first.stdout, "takeover succeeded; holder is demo-beta"
    assert_includes first.stdout, "temporary state removed"
  end

  def test_demo_ignores_remote_backends_and_removes_isolated_state
    expected_refusal = "CLAIM_REFUSED: active claim for demo/example#1 held by demo-alpha; heartbeat live"
    Dir.mktmpdir("agent-coord-demo-tmp") do |tmpdir|
      xdg_state_home = File.join(tmpdir, "xdg-state")
      common_env = { "TMPDIR" => tmpdir, "XDG_STATE_HOME" => xdg_state_home }
      clean = run_command(common_env, RbConfig.ruby, BIN, "demo")
      configured = run_command(
        common_env.merge(
          "AGENT_COORD_API_URL" => "http://127.0.0.1:1",
          "AGENT_COORD_API_TOKEN" => "demo-must-not-use-this-token",
          "AGENT_COORD_BACKEND" => "demo/must-not-use-this-repo",
          "AGENT_COORD_STATE_ROOT" => File.join(tmpdir, "ambient-state"),
          "AGENT_COORD_STATUS_STATE_ROOT" => File.join(tmpdir, "ambient-status-state")
        ),
        RbConfig.ruby,
        BIN,
        "demo"
      )

      assert_equal 0, clean.status.exitstatus, clean.stderr
      assert_equal 0, configured.status.exitstatus, configured.stderr
      assert_equal clean.stdout, configured.stdout
      assert_includes configured.stdout, expected_refusal
      refute_includes configured.stdout, "warning:"
      assert_empty clean.stderr
      assert_empty configured.stderr
      assert_demo_left_no_state(tmpdir, xdg_state_home)
    end
  end

  def test_global_help_omits_doctor_only_deep_option
    result = run_agent_coord("--help", state_root: nil)
    doctor = run_agent_coord("doctor", "--help", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stdout, "--deep"
    refute_includes result.stdout, "--doctor-prefix"
    assert_includes doctor.stdout, "--deep"
    assert_includes doctor.stdout, "--doctor-prefix"
  end

  def test_status_help_omits_doctor_only_deep_option
    result = run_agent_coord("status", "--help", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stdout, "--deep"
    refute_includes result.stdout, "--doctor-prefix"
  end

  def test_http_integration_harness_uses_portable_hashing_and_cleans_up_wrangler
    with_fake_http_harness do |env, paths|
      result = run_command(
        env,
        "bash",
        HTTP_INTEGRATION_BIN
      )

      assert_fake_http_harness_run(result, paths)
    end
  end

  def test_http_integration_harness_preserves_backend_test_failure_status
    with_fake_http_harness do |env, paths|
      result = run_command(
        env.merge("FAKE_BUNDLE_EXIT" => "42"),
        "bash",
        HTTP_INTEGRATION_BIN
      )

      assert_equal 42, result.status.exitstatus, "#{result.stdout}\n#{result.stderr}"
      assert_fake_harness_cleanup(paths)
    end
  end

  def test_version_json_exposes_cli_contract_version
    result = run_agent_coord("version", "--json", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr

    payload = JSON.parse(result.stdout)
    assert_match(/\A\d+\.\d+\.\d+\z/, payload.fetch("version"))
    assert_equal 1, payload.fetch("schema_version")
    assert_equal 2, payload.fetch("lane_closed_schema_version")
    assert_nil payload.fetch("default_backend")
    assert_equal "state", payload.fetch("default_ref")
  end

  def test_version_text_renders_missing_default_backend_as_none
    result = run_agent_coord("version", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "default_backend: none"
  end

  def test_config_json_exposes_runtime_defaults_and_exit_codes
    result = run_agent_coord("config", "--json", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr

    payload = JSON.parse(result.stdout)
    assert_equal 4 * 60 * 60, payload.fetch("default_claim_ttl_seconds")
    assert_equal 15 * 60, payload.fetch("default_heartbeat_ttl_seconds")
    assert_equal 4, payload.fetch("heartbeat_dead_after_ttl_multiplier")
    assert_includes payload.fetch("dependency_terminal_statuses"), "done"
    assert_equal 3, payload.fetch("exit_codes").fetch("claim_refused")
    assert_equal 2, payload.fetch("exit_codes").fetch("operational")
  end

  def test_config_text_renders_missing_default_backend_as_none
    result = run_agent_coord("config", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "default_backend: none"
  end

  def test_unconfigured_status_defaults_to_labeled_xdg_local_store
    Dir.mktmpdir("agent-coord-xdg-state") do |state_home|
      result = run_command(
        { "XDG_STATE_HOME" => state_home },
        RbConfig.ruby,
        BIN,
        "status",
        "--json"
      )

      assert_equal 0, result.status.exitstatus, result.stderr
      assert_equal "all", JSON.parse(result.stdout).dig("scope", "kind")
      assert_includes result.stderr, "local mode — single-machine only"
      assert_includes result.stderr, File.join(state_home, "agent-coordination")
    end
  end

  def test_unconfigured_claim_persists_only_to_labeled_xdg_local_store
    Dir.mktmpdir("agent-coord-zero-config-claim") do |root|
      state_home = File.join(root, "xdg-state")
      home = File.join(root, "home")
      state_root = File.join(state_home, "agent-coordination")
      env = COMMAND_ENV.merge(
        "XDG_STATE_HOME" => state_home,
        "HOME" => home,
        "TMPDIR" => File.join(root, "tmp"),
        "PATH" => "/nonexistent"
      )
      result = run_command(
        env, RbConfig.ruby, BIN, "claim",
        "--agent-id", "zero-config-worker", "--repo", "demo/example", "--target", "1"
      )

      assert_equal 0, result.status.exitstatus, result.stderr
      assert_includes result.stdout, "claimed demo/example#1 by zero-config-worker until "
      assert_includes result.stderr, "local mode — single-machine only"
      assert_includes result.stderr, "state root: #{state_root}"
      claim_path = File.join(state_root, "claims", "demo", "example", "1.json")
      claim = JSON.parse(File.read(claim_path))
      assert_equal "zero-config-worker", claim.fetch("agent_id")
      assert_equal "demo/example", claim.fetch("repo")
      assert_equal "1", claim.fetch("target")
      assert_equal "active", claim.fetch("status")
      refute_path_exists File.join(home, ".local", "state", "agent-coordination")
      assert_equal ["xdg-state"], Dir.children(root).sort
    end
  end

  def test_unconfigured_doctor_initializes_and_reports_xdg_local_store
    Dir.mktmpdir("agent-coord-xdg-state") do |state_home|
      state_root = File.join(state_home, "agent-coordination")
      result = run_command(
        { "XDG_STATE_HOME" => state_home },
        RbConfig.ruby,
        BIN,
        "doctor"
      )

      assert_equal 0, result.status.exitstatus, result.stderr
      assert_includes result.stdout, "backend: local"
      assert_includes result.stdout, "state_root: #{state_root}"
      assert_includes result.stderr, "local mode — single-machine only"
      assert_path_exists state_root
    end
  end

  def test_relative_xdg_state_home_uses_home_fallback_independent_of_cwd
    Dir.mktmpdir("agent-coord-relative-xdg") do |root|
      home = File.join(root, "home")
      cwd_a = File.join(root, "cwd-a")
      cwd_b = File.join(root, "cwd-b")
      FileUtils.mkdir_p([cwd_a, cwd_b])
      env = {
        "XDG_STATE_HOME" => "relative-state",
        "HOME" => home,
        "TMPDIR" => File.join(root, "tmp")
      }
      status = Dir.chdir(cwd_a) { run_command(env, RbConfig.ruby, BIN, "status", "--json") }
      doctor = Dir.chdir(cwd_b) { run_command(env, RbConfig.ruby, BIN, "doctor") }
      expected_root = File.join(home, ".local", "state", "agent-coordination")

      assert_equal 0, status.status.exitstatus, status.stderr
      assert_equal "all", JSON.parse(status.stdout).dig("scope", "kind")
      assert_equal 0, doctor.status.exitstatus, doctor.stderr
      assert_includes status.stderr, "state root: #{expected_root}"
      assert_includes doctor.stderr, "state root: #{expected_root}"
      assert_includes doctor.stdout, "state_root: #{expected_root}"
      assert_path_exists expected_root
      refute_path_exists File.join(cwd_a, "relative-state", "agent-coordination")
      refute_path_exists File.join(cwd_b, "relative-state", "agent-coordination")
    end
  end

  def test_token_only_http_env_rejects_implicit_source_state_for_status_and_doctor
    with_agent_coord_source_state do |bin, source_root|
      xdg_state_home = File.join(source_root, "xdg-state")

      [nil, ""].each do |api_url|
        [["status", "--json"], ["doctor"]].each do |args|
          result = run_command(
            {
              "AGENT_COORD_API_URL" => api_url,
              "AGENT_COORD_API_TOKEN" => "token-without-url",
              "XDG_STATE_HOME" => xdg_state_home,
              "HOME" => File.join(source_root, "home"),
              "TMPDIR" => File.join(source_root, "tmp")
            },
            RbConfig.ruby,
            bin,
            *args
          )

          assert_equal 2, result.status.exitstatus
          assert_empty result.stdout
          assert_includes result.stderr, "AGENT_COORD_API_TOKEN is set but AGENT_COORD_API_URL is missing or empty"
          refute_includes result.stderr, "local mode — single-machine only"
        end
      end

      refute_path_exists File.join(xdg_state_home, "agent-coordination")
      assert_empty Dir.glob(File.join(source_root, "{claims,heartbeats,batches,events}", "**", "*.json"))
    end
  end

  def test_doctor_verifies_local_backend_without_github
    result = run_agent_coord("doctor")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "agent-coord doctor"
    assert_includes result.stdout, "backend: local"
    assert_includes result.stdout, "status: ok"
  end

  def test_doctor_lightweight_does_not_parse_local_json_by_default
    FileUtils.mkdir_p(File.join(@state_root, "heartbeats"))
    File.write(File.join(@state_root, "heartbeats", "broken.json"), "{")

    result = run_agent_coord("doctor")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "status: ok"
  end

  def test_doctor_deep_reports_malformed_local_state_as_operational_error
    FileUtils.mkdir_p(File.join(@state_root, "heartbeats"))
    File.write(File.join(@state_root, "heartbeats", "broken.json"), "{")

    result = run_agent_coord("doctor", "--deep")

    assert_equal 2, result.status.exitstatus
    assert_includes result.stderr, "state unreadable"
    refute_includes result.stderr, "from "
  end

  def test_doctor_deep_checks_all_local_state_prefixes
    %w[claims batches events].each do |prefix|
      state_root = Dir.mktmpdir("agent-coord-test")
      FileUtils.mkdir_p(File.join(state_root, prefix))
      File.write(File.join(state_root, prefix, "broken.json"), "{")

      result = run_agent_coord("doctor", "--deep", state_root: state_root)

      assert_equal 2, result.status.exitstatus, "#{prefix}: #{result.stdout} #{result.stderr}"
      assert_includes result.stderr, "state unreadable"
      refute_includes result.stdout, "status: ok"
    ensure
      FileUtils.remove_entry(state_root) if state_root && Dir.exist?(state_root)
    end
  end

  def test_doctor_rejects_file_state_root
    state_root = File.join(@state_root, "state-root-file")
    File.write(state_root, "not a directory")

    result = run_agent_coord("doctor", state_root: state_root)

    assert_equal 2, result.status.exitstatus
    assert_includes result.stderr, "state root is not a directory"
    refute_includes result.stdout, "status: ok"
  end

  def test_doctor_rejects_local_prefix_file_layout
    File.write(File.join(@state_root, "claims"), "not a directory")

    result = run_agent_coord("doctor")

    assert_equal 2, result.status.exitstatus
    assert_includes result.stderr, "state layout invalid"
    assert_includes result.stderr, "claims is not a directory"
    refute_includes result.stdout, "status: ok"
  end

  def test_doctor_reports_missing_gh_as_operational_error
    with_agent_coord_without_source_state do |bin|
      result = run_command(
        { "AGENT_COORD_STATE_ROOT" => nil, "AGENT_COORD_STATUS_STATE_ROOT" => nil, "PATH" => "/nonexistent" },
        RbConfig.ruby,
        bin,
        "doctor",
        "--backend",
        "shakacode/agent-coordination-state"
      )

      assert_equal 2, result.status.exitstatus
      assert_includes result.stderr, "gh auth status failed"
      refute_includes result.stderr, "from "
    end
  end

  def test_unconfigured_doctor_defaults_to_home_local_store_when_xdg_state_home_is_empty
    Dir.mktmpdir("agent-coord-home") do |home|
      with_agent_coord_without_source_state do |bin|
        state_root = File.join(home, ".local", "state", "agent-coordination")
        result = run_command(
          {
            "AGENT_COORD_STATE_ROOT" => nil,
            "AGENT_COORD_STATUS_STATE_ROOT" => nil,
            "XDG_STATE_HOME" => "",
            "HOME" => home
          },
          RbConfig.ruby,
          bin,
          "doctor"
        )

        assert_equal 0, result.status.exitstatus, result.stderr
        assert_includes result.stdout, "backend: local"
        assert_includes result.stdout, "state_root: #{state_root}"
        assert_includes result.stderr, "local mode — single-machine only"
        assert_path_exists state_root
      end
    end
  end

  def test_doctor_rejects_unreadable_github_ref
    fake_bin = Dir.mktmpdir("agent-coord-gh")
    write_fake_gh(fake_bin)

    with_agent_coord_without_source_state do |bin|
      result = run_command(
        {
          "AGENT_COORD_STATE_ROOT" => nil,
          "AGENT_COORD_STATUS_STATE_ROOT" => nil,
          "PATH" => [fake_bin, File.dirname(RbConfig.ruby)].join(File::PATH_SEPARATOR)
        },
        RbConfig.ruby,
        bin,
        "doctor",
        "--backend",
        "shakacode/agent-coordination-state",
        "--ref",
        "missing-ref"
      )

      assert_equal 2, result.status.exitstatus
      assert_includes result.stderr, "backend ref"
      assert_includes result.stderr, "missing-ref"
      refute_includes result.stdout, "status: ok"
    end
  ensure
    FileUtils.remove_entry(fake_bin) if fake_bin && Dir.exist?(fake_bin)
  end

  def test_deep_option_is_doctor_only
    result = run_agent_coord("status", "--deep")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "--deep is only valid for doctor"
  end

  def test_doctor_help_accepts_deep_option
    result = run_agent_coord("doctor", "--deep", "--help", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "--deep"
    assert_includes result.stdout, "--doctor-prefix"
  end

  def test_non_doctor_deep_guard_ignores_deep_as_option_value
    commands = [
      ["status", "--branch", "--deep", "--json"],
      ["release", "--agent-id", "a", "--repo", "o/r", "--target", "1", "--terminal", "--deep"],
      ["release", "--agent-id", "a", "--repo", "o/r", "--target", "1", "--pr-state", "--deep"],
      ["release", "--agent-id", "a", "--repo", "o/r", "--target", "1", "--evidence-url", "--deep"],
      ["release", "--agent-id", "a", "--repo", "o/r", "--target", "1", "--workspace", "--deep"]
    ]
    commands.each do |args|
      result = run_agent_coord(*args)
      refute_includes result.stderr, "--deep is only valid for doctor"
    end
  end

  def test_bootstrap_installs_command_and_removes_generated_underscore_alias
    install_dir = Dir.mktmpdir("agent-coord-bin")
    legacy_alias = File.join(install_dir, "agent_coord")
    FileUtils.ln_sf(File.join(ROOT, "bin", "agent_coord"), legacy_alias)

    result = run_agent_coord("bootstrap", "--install-dir", install_dir, "--no-profile", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "installed agent-coord"
    assert_includes result.stdout, "removed legacy agent_coord"
    assert File.exist?(File.join(install_dir, "agent-coord"))
    refute File.exist?(legacy_alias)
    refute File.symlink?(legacy_alias)
  ensure
    FileUtils.remove_entry(install_dir) if install_dir && Dir.exist?(install_dir)
  end

  def test_bootstrap_can_install_status_state_root_wrappers
    install_dir = Dir.mktmpdir("agent-coord-bin")
    legacy_alias = File.join(install_dir, "agent_coord")
    legacy_state_root = File.join(@state_root, "status-root-#{'x' * 700}")
    File.write(
      legacy_alias,
      <<~SH
        #!/bin/sh
        export AGENT_COORD_STATUS_STATE_ROOT=#{Shellwords.escape(legacy_state_root)}
        exec #{Shellwords.escape(File.join(ROOT, 'bin', 'agent_coord'))} "$@"
      SH
    )
    FileUtils.chmod(0o755, legacy_alias)

    now = Time.now.utc
    write_heartbeat(
      "worker-bootstrap-wrapper",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )

    result = run_agent_coord(
      "bootstrap",
      "--install-dir", install_dir,
      "--status-state-root", @state_root,
      "--no-profile",
      state_root: nil
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    wrapper = File.join(install_dir, "agent-coord")
    assert File.executable?(wrapper)
    assert_includes File.read(wrapper), "AGENT_COORD_STATUS_STATE_ROOT"
    refute File.exist?(legacy_alias)

    status = run_command({ "AGENT_COORD_STATE_ROOT" => nil }, wrapper, "status")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes status.stdout, "worker-bootstrap-wrapper"
  ensure
    FileUtils.remove_entry(install_dir) if install_dir && Dir.exist?(install_dir)
  end

  def test_bootstrap_leaves_unrelated_underscore_command_untouched
    install_dir = Dir.mktmpdir("agent-coord-bin")
    unrelated_alias = File.join(install_dir, "agent_coord")
    unrelated_content = <<~SH
      #!/bin/sh
      echo personal helper
    SH
    File.write(unrelated_alias, unrelated_content)
    FileUtils.chmod(0o755, unrelated_alias)

    result = run_agent_coord("bootstrap", "--install-dir", install_dir, "--no-profile", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "installed agent-coord"
    refute_includes result.stdout, "removed legacy agent_coord"
    assert_equal unrelated_content, File.read(unrelated_alias)
    assert File.executable?(unrelated_alias)
  ensure
    FileUtils.remove_entry(install_dir) if install_dir && Dir.exist?(install_dir)
  end

  def test_bootstrap_leaves_binary_underscore_command_untouched
    install_dir = Dir.mktmpdir("agent-coord-bin")
    unrelated_alias = File.join(install_dir, "agent_coord")
    binary_content = "\xff\xfe\x00not a shell wrapper".b
    File.binwrite(unrelated_alias, binary_content)
    FileUtils.chmod(0o755, unrelated_alias)

    result = run_agent_coord("bootstrap", "--install-dir", install_dir, "--no-profile", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "installed agent-coord"
    refute_includes result.stdout, "removed legacy agent_coord"
    assert_equal binary_content, File.binread(unrelated_alias)
    assert File.executable?(unrelated_alias)
  ensure
    FileUtils.remove_entry(install_dir) if install_dir && Dir.exist?(install_dir)
  end

  def test_bootstrap_reports_install_dir_errors_as_operational
    install_dir = File.join(@state_root, "install-dir-file")
    File.write(install_dir, "not a directory")

    result = run_agent_coord("bootstrap", "--install-dir", install_dir, "--no-profile", state_root: nil)

    assert_equal 2, result.status.exitstatus
    assert_includes result.stderr, "bootstrap failed"
    refute_includes result.stderr, "from "
  end

  def test_bootstrap_shell_escapes_profile_path_entry
    install_dir = File.join(@state_root, "bin $(touch should-not-run)")
    profile = File.join(@state_root, "profile")

    result = run_agent_coord("bootstrap", "--install-dir", install_dir, "--profile", profile, state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr

    profile_content = File.read(profile)
    expanded_install_dir = File.expand_path(install_dir)
    assert_includes profile_content, "export PATH=#{Shellwords.escape(expanded_install_dir)}:\"$PATH\""
    refute_includes profile_content, "export PATH=\"#{expanded_install_dir}:$PATH\""
  end

  def test_bootstrap_profile_idempotence_requires_exact_path_line
    install_dir = File.join(@state_root, "bin")
    profile = File.join(@state_root, "profile")
    File.write(profile, "export PATH=#{Shellwords.escape("#{install_dir}-old")}:\"$PATH\"\n")

    result = run_agent_coord("bootstrap", "--install-dir", install_dir, "--profile", profile, state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes File.read(profile), "export PATH=#{Shellwords.escape(install_dir)}:\"$PATH\""
  end

  def test_systemd_template_leaves_status_default_for_shell_expansion
    template = File.read(SYSTEMD_TEMPLATE)

    assert_includes template, 'Environment="PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin"'
    assert_includes template, 'Environment="AGENT_COORD_STATUS=in_progress"'
    assert_includes template, "EnvironmentFile=__AGENT_COORD_ENV_FILE__"
    assert_includes template, "ExecStart=/bin/bash -lc"
    assert_includes template, 'AGENT_COORD_API_URL:?set AGENT_COORD_API_URL'
    assert_includes template, 'AGENT_COORD_API_TOKEN:?set AGENT_COORD_API_TOKEN'
    assert_includes template, '--status "$$AGENT_COORD_STATUS"'
    assert_includes template, 'Environment="BRANCH=__BRANCH__"'
    refute_match(/ExecStart=.*__BRANCH__/, template)
  end

  def test_scheduler_templates_use_cli_without_state_branch_pinning
    launchd_heartbeat = File.read(LAUNCHD_HEARTBEAT_TEMPLATE)
    systemd_heartbeat = File.read(SYSTEMD_TEMPLATE)

    assert_includes launchd_heartbeat, "bin/agent-coord heartbeat"
    assert_includes systemd_heartbeat, "bin/agent-coord heartbeat"
    assert_includes launchd_heartbeat, "__AGENT_COORD_ENV_FILE__"
    assert_includes systemd_heartbeat, "__AGENT_COORD_ENV_FILE__"
    assert_includes launchd_heartbeat, 'AGENT_COORD_API_URL:?set in __AGENT_COORD_ENV_FILE__'
    refute_includes launchd_heartbeat, "AGENT_COORD_REF=state"
    refute_includes systemd_heartbeat, "AGENT_COORD_REF=state"
  end

  def test_readme_documents_local_first_run_and_team_http_setup
    readme = File.read(File.join(ROOT, "README.md"))

    assert_includes readme, "A zero-config first run uses a clearly labeled local store"
    assert_includes readme, "The team and multi-machine runtime path is the HTTP"
    assert_includes readme, "$XDG_STATE_HOME/agent-coordination"
    assert_includes readme, "when `XDG_STATE_HOME` is an absolute path"
    assert_includes readme, "Relative, empty, or unset values use"
    assert_includes readme, "~/.local/state/agent-coordination"
    assert_includes readme, "local mode — single-machine only"
    assert_includes readme, "agent-coord demo"
    assert_includes readme, "never writes demo data remotely"
    assert_includes readme, "AGENT_COORD_API_URL"
    assert_includes readme, "AGENT_COORD_API_TOKEN"
    assert_includes readme, "AGENT_COORD_ENV_FILE"
    assert_includes readme, "Deploy the Worker/D1 backend"
    assert_includes readme, "npx wrangler d1 migrations apply agent-coord --remote"
    assert_includes readme, 'curl -fsS "$AGENT_COORD_API_URL/v1/health"'
    assert_includes readme, 'install -m 600 /dev/null "$AGENT_COORD_ENV_FILE"'
    assert_includes readme, "cat > \"$AGENT_COORD_ENV_FILE\" <<'EOF'\nAGENT_COORD_API_URL=<worker-url>"
    refute_includes readme, "cat > \"$AGENT_COORD_ENV_FILE\" <<'EOF'\nexport AGENT_COORD_API_URL"
    assert_includes readme, "Keep this public repository code-only"
    refute_includes readme, "agent_coord --help"
    refute_includes readme, "git clone --branch state --single-branch"
  end

  def test_operational_holder_heartbeat_read_failure_is_not_treated_as_missing
    runner = AgentCoord::Runner.new([])
    store = Class.new do
      def read_json(_path)
        raise AgentCoord::OperationalError, "gh api failed"
      end
    end.new

    error = assert_raises(AgentCoord::OperationalError) do
      runner.send(:read_holder_heartbeat, store, "worker-a")
    end
    assert_equal 2, error.exit_code
  end

  def test_github_store_verifies_ref_before_treating_content_404_as_missing
    store = MissingContentVerifiesRefGitHubStore.new

    assert_nil store.read_json("claims/shakacode/react_on_rails/4150.json")
    assert_equal 1, store.ref_reads
  end

  def test_github_store_reports_unreadable_ref_before_treating_content_404_as_missing
    store = MissingContentUnreadableRefGitHubStore.new

    error = assert_raises(AgentCoord::OperationalError) do
      store.read_json("claims/shakacode/react_on_rails/4150.json")
    end
    assert_includes error.message, "backend ref"
  end

  def test_github_store_invalidates_cached_json_after_write_conflict
    store = ConflictCachingGitHubStore.new
    path = "heartbeats/worker-a.json"

    first = store.read_json(path)
    assert_equal "old", first.data.fetch("status")

    assert_raises(AgentCoord::Conflict) do
      store.write_json(path, { "status" => "ours" }, message: "Heartbeat worker-a", sha: first.sha)
    end

    second = store.read_json(path)
    assert_equal "new", second.data.fetch("status")
    assert_equal "sha-new", second.sha
  end

  def test_github_store_invalidates_cached_tree_after_write_conflict
    store = ConflictTreeCachingGitHubStore.new
    path = "heartbeats/worker-a.json"

    assert_equal [path], store.list_json("heartbeats").map(&:path)

    first = store.read_json(path)
    assert_raises(AgentCoord::Conflict) do
      store.write_json(path, { "status" => "ours" }, message: "Heartbeat worker-a", sha: first.sha)
    end

    assert_equal [path, "heartbeats/worker-b.json"], store.list_json("heartbeats").map(&:path)
    assert_equal 2, store.tree_reads
  end

  def test_github_store_invalidates_cached_tree_after_create_conflict
    store = CreateConflictTreeInvalidationGitHubStore.new
    path = "heartbeats/worker-a.json"

    assert_empty store.list_json("heartbeats")

    assert_raises(AgentCoord::Conflict) do
      store.write_json(path, { "status" => "ours" }, message: "Heartbeat worker-a", create: true)
    end

    assert_equal [path], store.list_json("heartbeats").map(&:path)
    assert_equal 2, store.tree_reads
  end

  def test_github_store_invalidates_cached_tree_after_write_success
    store = TreeInvalidationGitHubStore.new
    path = "claims/shakacode/react_on_rails/4150.json"

    assert_empty store.list_json("claims")

    store.write_json(
      path,
      {
        "repo" => "shakacode/react_on_rails",
        "target" => "4150",
        "status" => "active"
      },
      message: "Claim 4150",
      create: true
    )

    entries = store.list_json("claims")
    assert_equal [path], entries.map(&:path)
    assert_equal 2, store.tree_reads
  end

  def test_github_layout_requires_exact_prefix_nodes_to_be_trees
    store = BlobPrefixLayoutGitHubStore.new

    error = assert_raises(AgentCoord::OperationalError) do
      store.verify_layout!(%w[claims heartbeats batches])
    end
    assert_includes error.message, "claims"
  end

  def test_github_layout_allows_empty_prefixes
    store = EmptyLayoutGitHubStore.new

    store.verify_layout!(%w[claims heartbeats batches])
  end

  def test_github_store_reports_context_for_unreadable_recursive_tree
    store = UnreadableTreeGitHubStore.new

    error = assert_raises(AgentCoord::OperationalError) do
      store.verify_readable!
    end
    assert_includes error.message, "backend ref shakacode/agent-coordination-state@state is not readable"
    assert_includes error.message, "rate limit"
  end

  def test_segment_validation_rejects_consecutive_dots_before_path_validation
    error = assert_raises(AgentCoord::PathValidationError) do
      AgentCoord.batch_path("bad..batch")
    end

    assert_equal "invalid batch-id: bad..batch", error.message
  end

  def test_claim_cas_conflict_is_operational_not_claim_refused
    runner = AgentCoord::Runner.new([])
    store = Class.new do
      def read_json(_path)
        nil
      end

      def write_json(*)
        raise AgentCoord::Conflict, "state changed at claim"
      end
    end.new
    runner.define_singleton_method(:build_store) { |_options| store }

    error = assert_raises(AgentCoord::OperationalError) do
      runner.send(
        :claim,
        agent_id: "worker-a",
        repo: "shakacode/react_on_rails",
        target: "3971",
        ttl: 3600
      )
    end
    assert_equal 2, error.exit_code
    refute_match(/CLAIM_REFUSED/, error.message)
  end

  def test_heartbeat_upserts_local_state_and_status_reads_it
    result = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-3969",
      "--repo", "shakacode/react_on_rails",
      "--target", "3969",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/3969-agent-coord-backend",
      "--ttl", "3600",
      "--status", "in_progress"
    )

    assert_equal 0, result.status.exitstatus, result.stderr

    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-3969.json")))
    assert_equal 1, heartbeat.fetch("schema_version")
    assert_equal "worker-3969", heartbeat.fetch("agent_id")
    assert_equal "shakacode/react_on_rails", heartbeat.fetch("repo")
    assert_equal "3969", heartbeat.fetch("target")

    status = run_agent_coord("status")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes status.stdout, "heartbeats"
    assert_includes status.stdout, "worker-3969"
    assert_includes status.stdout, "3969"
  end

  def test_status_classifies_heartbeat_liveness_from_timestamps
    now = Time.now.utc
    write_heartbeat(
      "worker-live",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )
    write_heartbeat(
      "worker-stale",
      updated_at: now - (20 * 60),
      expires_at: now - (5 * 60)
    )
    write_heartbeat(
      "worker-dead",
      updated_at: now - (70 * 60),
      expires_at: now - (55 * 60)
    )

    status = run_agent_coord("status")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_match(/worker-live .* live /, status.stdout)
    assert_match(/worker-stale .* stale /, status.stdout)
    assert_match(/worker-dead .* dead /, status.stdout)
  end

  def test_status_defaults_to_status_state_root_without_global_state_root
    now = Time.now.utc
    write_heartbeat(
      "worker-local-default",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )
    fake_bin = Dir.mktmpdir("agent-coord-gh")
    File.write(File.join(fake_bin, "gh"), "#!/bin/sh\necho unexpected gh >&2\nexit 42\n")
    FileUtils.chmod(0o755, File.join(fake_bin, "gh"))

    result = run_command(
      {
        "AGENT_COORD_STATE_ROOT" => nil,
        "AGENT_COORD_STATUS_STATE_ROOT" => @state_root,
        "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR)
      },
      RbConfig.ruby,
      BIN,
      "status"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "worker-local-default"
    refute_includes result.stderr, "unexpected gh"
  ensure
    FileUtils.remove_entry(fake_bin) if fake_bin && Dir.exist?(fake_bin)
  end

  def test_doctor_defaults_to_status_state_root_without_global_state_root
    now = Time.now.utc
    write_heartbeat(
      "worker-doctor-local-default",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )
    fake_bin = Dir.mktmpdir("agent-coord-gh")
    File.write(File.join(fake_bin, "gh"), "#!/bin/sh\necho unexpected gh >&2\nexit 42\n")
    FileUtils.chmod(0o755, File.join(fake_bin, "gh"))

    result = run_command(
      {
        "AGENT_COORD_STATE_ROOT" => nil,
        "AGENT_COORD_STATUS_STATE_ROOT" => @state_root,
        "PATH" => [fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR)
      },
      RbConfig.ruby,
      BIN,
      "doctor"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "backend: local"
    assert_includes result.stdout, "state_root: #{@state_root}"
    refute_includes result.stderr, "unexpected gh"
  ensure
    FileUtils.remove_entry(fake_bin) if fake_bin && Dir.exist?(fake_bin)
  end

  def test_claim_rejects_active_claim_and_allows_after_release
    first_claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3969",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/a",
      "--ttl", "3600"
    )

    assert_equal 0, first_claim.status.exitstatus, first_claim.stderr

    competing_claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-b",
      "--repo", "shakacode/react_on_rails",
      "--target", "3969",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/b",
      "--ttl", "3600"
    )

    refute_equal 0, competing_claim.status.exitstatus
    assert_equal 3, competing_claim.status.exitstatus
    assert_includes competing_claim.stderr, "active claim"
    assert_includes competing_claim.stderr, "CLAIM_REFUSED"

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3969"
    )

    assert_equal 0, release.status.exitstatus, release.stderr

    second_claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-b",
      "--repo", "shakacode/react_on_rails",
      "--target", "3969",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/b",
      "--ttl", "3600"
    )

    assert_equal 0, second_claim.status.exitstatus, second_claim.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3969.json")
    claim = JSON.parse(File.read(claim_path))
    assert_equal "worker-b", claim.fetch("agent_id")
    assert_equal "active", claim.fetch("status")
  end

  def test_release_persists_branch_supplied_after_claim
    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3970",
      "--ttl", "3600"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3970",
      "--branch", "jg-codex/released-branch"
    )
    assert_equal 0, release.status.exitstatus, release.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3970.json")
    payload = JSON.parse(File.read(claim_path))
    assert_equal "released", payload.fetch("status")
    assert_equal "jg-codex/released-branch", payload.fetch("branch")
  end

  def test_claim_and_heartbeat_round_trip_lane_metadata
    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3973",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "claimed", pr_url: nil)
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    heartbeat = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3973",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "validating")
    )
    assert_equal 0, heartbeat.status.exitstatus, heartbeat.stderr

    status = run_agent_coord("status", "--repo", "shakacode/react_on_rails", "--target", "3973", "--json")
    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    claim_payload = payload.fetch("claims").first
    heartbeat_payload = payload.fetch("heartbeats").first

    assert_lane_metadata(claim_payload, phase: "claimed", pr_url: nil)
    assert_lane_metadata(heartbeat_payload, phase: "validating")
  end

  def test_release_updates_lane_metadata
    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3973"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3973",
      "--pr-url", "https://github.com/shakacode/react_on_rails/pull/3973",
      "--phase", "merged"
    )
    assert_equal 0, release.status.exitstatus, release.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3973.json")
    released_payload = JSON.parse(File.read(claim_path))
    assert_equal "released", released_payload.fetch("status")
    assert_equal "https://github.com/shakacode/react_on_rails/pull/3973", released_payload.fetch("pr_url")
    assert_equal "merged", released_payload.fetch("phase")
  end

  def test_terminal_release_closes_lane_and_completes_single_lane_batch
    write_batch(
      "batch-terminal",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3980"] }]
    )
    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3980",
      "--batch-id", "batch-terminal",
      "--branch", "jg-codex/terminal",
      "--host", "codex"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr
    heartbeat = run_agent_coord(
      "heartbeat", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3980", "--batch-id", "batch-terminal", "--status", "in_progress"
    )
    assert_equal 0, heartbeat.status.exitstatus, heartbeat.stderr

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3980",
      "--terminal", "done",
      "--pr-url", "HTTPS://github.com/shakacode/react_on_rails/pull/3980",
      "--pr-state", "merged", "--evidence-url", "HtTpS://example.test/evidence/3980"
    )

    assert_equal 0, release.status.exitstatus, release.stderr
    assert_terminal_release_state
  end

  def assert_terminal_release_state
    claim_payload = JSON.parse(
      File.read(File.join(@state_root, "claims", "shakacode", "react_on_rails", "3980.json"))
    )
    assert_equal "released", claim_payload.fetch("status")
    assert_equal "done", claim_payload.fetch("terminal")

    event_path = Dir.glob(File.join(@state_root, "events", "batch-terminal", "*.json")).fetch(0)
    event = JSON.parse(File.read(event_path))
    assert_equal 2, event.fetch("schema_version")
    assert_equal "lane_closed", event.fetch("type")
    assert_equal "code", event.fetch("lane")
    assert_equal "done", event.fetch("terminal")
    assert_equal "default", event.fetch("workspace")
    assert_equal({ "agent_id" => "worker-a", "machine" => "codex" }, event.fetch("closed_by"))
    assert_equal "merged", event.fetch("pr_state")
    contract = JSONSchemer.schema(JSON.parse(File.read(File.join(ROOT, "contracts", "state-schema-v2.json"))))
    assert_empty contract.validate(event).to_a

    batch = JSON.parse(File.read(File.join(@state_root, "batches", "batch-terminal.json")))
    assert_equal "completed", batch.fetch("status")
    assert_equal "done", batch.fetch("lanes").fetch(0).fetch("terminal")

    status = run_agent_coord("status", "--batch-id", "batch-terminal", "--json")
    assert_equal 0, status.status.exitstatus, status.stderr
    status_lane = JSON.parse(status.stdout).fetch("batches").fetch(0).fetch("lanes").fetch(0)
    assert_equal "done", status_lane.fetch("status"), "declared terminal state must beat stale heartbeat state"
    assert_equal "done", status_lane.fetch("terminal")
  end

  def test_terminal_release_without_registered_batch_does_not_release_claim
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "3983"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    release = run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3983", "--terminal", "done"
    )

    assert_equal 1, release.status.exitstatus
    assert_includes release.stderr, "terminal release requires a claim with batch_id"
    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3983.json")
    assert_equal "active", JSON.parse(File.read(claim_path)).fetch("status")
    refute_path_exists File.join(@state_root, "events")
  end

  def test_terminal_release_closes_legacy_id_only_lane
    write_batch(
      "batch-legacy-id",
      lanes: [{ "id" => "legacy", "owner" => "worker-a", "targets" => ["3985"] }]
    )
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3985", "--batch-id", "batch-legacy-id"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    release = run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3985", "--terminal", "done"
    )

    assert_equal 0, release.status.exitstatus, release.stderr
    event_path = Dir.glob(File.join(@state_root, "events", "batch-legacy-id", "*.json")).fetch(0)
    assert_equal "legacy", JSON.parse(File.read(event_path)).fetch("lane")
  end

  def test_concurrent_terminal_releases_reconcile_both_batch_lanes
    write_batch(
      "batch-concurrent-close",
      lanes: [
        { "name" => "one", "owner" => "worker-a", "targets" => ["3987"] },
        { "name" => "two", "owner" => "worker-b", "targets" => ["3988"] }
      ]
    )
    %w[worker-a worker-b].zip(%w[3987 3988]).each do |agent_id, target|
      claim = run_agent_coord(
        "claim", "--agent-id", agent_id, "--repo", "shakacode/react_on_rails",
        "--target", target, "--batch-id", "batch-concurrent-close"
      )
      assert_equal 0, claim.status.exitstatus, claim.stderr
    end

    store = ConcurrentBatchStore.new(@state_root, "batch-concurrent-close")
    errors = []
    threads = %w[worker-a worker-b].zip(%w[3987 3988]).map do |agent_id, target|
      Thread.new do
        runner = StoreInjectedRunner.new(
          ["release", "--agent-id", agent_id, "--repo", "shakacode/react_on_rails",
           "--target", target, "--terminal", "done"],
          store: store
        )
        runner.run
      rescue AgentCoord::Error => e
        errors << e
      end
    end
    threads.each(&:join)

    assert_empty errors
    batch = JSON.parse(File.read(File.join(@state_root, "batches", "batch-concurrent-close.json")))
    assert_equal "completed", batch.fetch("status")
    terminal_states = batch.fetch("lanes").map { |lane| lane.fetch("terminal") }
    assert_equal %w[done done], terminal_states
  end

  def test_concurrent_identical_lane_closed_events_share_one_atomic_reservation
    results, errors, event, batch = run_concurrent_terminal_events(%w[done done], "identical")

    assert_empty errors
    assert_equal [0, 0], results.sort
    expected_event_id = "lane_closed-#{Digest::SHA256.hexdigest('code')[0, 16]}"
    assert_equal expected_event_id, event.fetch("event_id")
    assert_equal "done", event.fetch("terminal")
    assert_equal "done", batch.fetch("lanes").fetch(0).fetch("terminal")
  end

  def test_concurrent_conflicting_lane_closed_events_keep_only_the_winner
    results, errors, event, batch = run_concurrent_terminal_events(%w[done abandoned], "conflicting")

    assert_equal [0], results
    assert_equal 1, errors.length
    assert_includes errors.fetch(0).message, "conflicting terminal closeout"
    assert_equal event.fetch("terminal"), batch.fetch("lanes").fetch(0).fetch("terminal")
  end

  def run_concurrent_terminal_events(terminals, suffix)
    batch_id = "batch-concurrent-same-lane-#{suffix}"
    target = suffix == "identical" ? "4010" : "4011"
    write_batch(
      batch_id,
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => [target] }]
    )
    store = ConcurrentTerminalEventStore.new(@state_root, batch_id)
    results = []
    errors = []
    threads = terminals.map do |terminal|
      Thread.new do
        runner = StoreInjectedRunner.new(
          ["record-event", "--batch-id", batch_id, "--type", "lane_closed", "--lane", "code",
           "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", target,
           "--host", "codex", "--terminal", terminal],
          store: store
        )
        results << runner.run
      rescue AgentCoord::Error => e
        errors << e
      end
    end
    threads.each(&:join)
    event_paths = Dir.glob(File.join(@state_root, "events", batch_id, "*.json"))
    assert_equal 1, event_paths.length
    event = JSON.parse(File.read(event_paths.fetch(0)))
    assert_equal event.fetch("event_id"), File.basename(event_paths.fetch(0), ".json")
    batch = JSON.parse(File.read(File.join(@state_root, "batches", "#{batch_id}.json")))
    [results, errors, event, batch]
  end

  def test_release_handoff_preserves_resume_metadata_and_records_event
    write_batch(
      "batch-handoff",
      lanes: [{ "name" => "docs", "owner" => "worker-a", "targets" => ["3975"] }]
    )
    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3975",
      "--batch-id", "batch-handoff",
      "--branch", "jg-codex/handoff",
      "--thread-handle", "thread-docs",
      "--host", "codex",
      "--pr-url", "https://github.com/shakacode/react_on_rails/pull/3975",
      "--operator", "justin",
      "--phase", "validating",
      "--generation", "4"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3975",
      "--handoff-to", "claude-code/conductor",
      "--handoff-note", "Continue from the failing docs spec."
    )
    assert_equal 0, release.status.exitstatus, release.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3975.json")
    assert_handoff_release_claim(JSON.parse(File.read(claim_path)))

    event_files = Dir.glob(File.join(@state_root, "events", "batch-handoff", "*.json"))
    assert_equal 1, event_files.length
    event = JSON.parse(File.read(event_files.first))
    assert_handoff_release_event(event)

    status = run_agent_coord("status", "--batch-id", "batch-handoff", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    status_event = JSON.parse(status.stdout).fetch("events").first
    assert_handoff_status_event(status_event, event.fetch("event_id"))
  end

  def test_release_handoff_without_batch_keeps_claim_metadata_without_event
    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3977"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3977",
      "--handoff-note", "Ready for another host to re-claim."
    )
    assert_equal 0, release.status.exitstatus, release.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3977.json")
    released_payload = JSON.parse(File.read(claim_path))
    assert_equal "released", released_payload.fetch("status")
    assert_equal "handoff", released_payload.fetch("release_mode")
    assert_equal "Ready for another host to re-claim.", released_payload.fetch("handoff_note")
    refute_path_exists File.join(@state_root, "events")
  end

  def test_non_handoff_release_clears_prior_handoff_metadata
    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3978"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    handoff = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3978",
      "--handoff-to", "worker-b",
      "--handoff-note", "Ready to continue."
    )
    assert_equal 0, handoff.status.exitstatus, handoff.stderr

    restamp = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3978",
      "--phase", "merged"
    )
    assert_equal 0, restamp.status.exitstatus, restamp.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3978.json")
    released_payload = JSON.parse(File.read(claim_path))
    assert_equal "released", released_payload.fetch("status")
    assert_equal "merged", released_payload.fetch("phase")
    refute_handoff_release_metadata(released_payload)
  end

  def test_handoff_release_replaces_prior_handoff_metadata
    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3979"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    first_handoff = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3979",
      "--handoff-to", "worker-b",
      "--handoff-note", "Ready to continue."
    )
    assert_equal 0, first_handoff.status.exitstatus, first_handoff.stderr

    second_handoff = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3979",
      "--handoff-note", "Waiting on reviewer."
    )
    assert_equal 0, second_handoff.status.exitstatus, second_handoff.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3979.json")
    released_payload = JSON.parse(File.read(claim_path))
    assert_equal "handoff", released_payload.fetch("release_mode")
    assert_equal "Waiting on reviewer.", released_payload.fetch("handoff_note")
    refute(released_payload.key?("handoff_to"), "expected handoff_to to be absent")
  end

  def test_release_handoff_tolerates_invalid_existing_batch_id
    claim_dir = File.join(@state_root, "claims", "shakacode", "react_on_rails")
    FileUtils.mkdir_p(claim_dir)
    File.write(
      File.join(claim_dir, "3979.json"),
      JSON.pretty_generate(
        "schema_version" => 1,
        "repo" => "shakacode/react_on_rails",
        "target" => "3979",
        "agent_id" => "worker-a",
        "batch_id" => "../bad",
        "status" => "active",
        "claimed_at" => Time.now.utc.iso8601,
        "updated_at" => Time.now.utc.iso8601,
        "expires_at" => (Time.now.utc + 3600).iso8601
      )
    )

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3979",
      "--handoff-note", "Continue elsewhere."
    )

    assert_equal 0, release.status.exitstatus, release.stderr
    assert_includes release.stderr, "warning: handoff event not recorded"
    released_payload = JSON.parse(File.read(File.join(claim_dir, "3979.json")))
    assert_equal "released", released_payload.fetch("status")
    assert_equal "handoff", released_payload.fetch("release_mode")
    assert_equal "Continue elsewhere.", released_payload.fetch("handoff_note")
  end

  def test_release_handoff_tolerates_local_event_write_failure
    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3980",
      "--batch-id", "batch-file"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr
    FileUtils.mkdir_p(File.join(@state_root, "events"))
    File.write(File.join(@state_root, "events", "batch-file"), "not a directory")

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3980",
      "--handoff-note", "Continue elsewhere."
    )

    assert_equal 0, release.status.exitstatus, release.stderr
    assert_includes release.stderr, "warning: handoff event not recorded"
    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3980.json")
    released_payload = JSON.parse(File.read(claim_path))
    assert_equal "released", released_payload.fetch("status")
    assert_equal "handoff", released_payload.fetch("release_mode")
    assert_equal "Continue elsewhere.", released_payload.fetch("handoff_note")
  end

  def test_release_rejects_metadata_update_from_non_holder_after_release
    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3978"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3978",
      "--pr-url", "https://github.com/shakacode/react_on_rails/pull/3978",
      "--phase", "merged"
    )
    assert_equal 0, release.status.exitstatus, release.stderr

    spoof = run_agent_coord(
      "release",
      "--agent-id", "worker-b",
      "--repo", "shakacode/react_on_rails",
      "--target", "3978",
      "--pr-url", "https://example.test/spoof",
      "--phase", "claimed"
    )
    refute_equal 0, spoof.status.exitstatus
    assert_includes spoof.stderr, "claim belongs to worker-a"

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3978.json")
    released_payload = JSON.parse(File.read(claim_path))
    assert_equal "worker-a", released_payload.fetch("agent_id")
    assert_equal "https://github.com/shakacode/react_on_rails/pull/3978", released_payload.fetch("pr_url")
    assert_equal "merged", released_payload.fetch("phase")
  end

  def test_claim_renewal_preserves_lane_metadata
    first_claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3974",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "claimed", pr_url: nil)
    )
    assert_equal 0, first_claim.status.exitstatus, first_claim.stderr

    renewal = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3974"
    )
    assert_equal 0, renewal.status.exitstatus, renewal.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3974.json")
    renewed_payload = JSON.parse(File.read(claim_path))
    assert_equal "batch-1", renewed_payload.fetch("batch_id")
    assert_equal "jg-codex/metadata", renewed_payload.fetch("branch")
    assert_lane_metadata(renewed_payload, phase: "claimed", pr_url: nil)
  end

  def test_claim_takeover_does_not_preserve_previous_holder_lane_metadata
    first_claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3976",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "merged")
    )
    assert_equal 0, first_claim.status.exitstatus, first_claim.stderr

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3976"
    )
    assert_equal 0, release.status.exitstatus, release.stderr

    takeover = run_agent_coord(
      "claim",
      "--agent-id", "worker-b",
      "--repo", "shakacode/react_on_rails",
      "--target", "3976"
    )
    assert_equal 0, takeover.status.exitstatus, takeover.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3976.json")
    takeover_payload = JSON.parse(File.read(claim_path))
    assert_equal "worker-b", takeover_payload.fetch("agent_id")
    assert_absent_lane_metadata(takeover_payload, "batch_id", "branch")
  end

  def test_claim_after_release_does_not_preserve_terminal_lane_metadata
    first_claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3979",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "claimed")
    )
    assert_equal 0, first_claim.status.exitstatus, first_claim.stderr

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3979",
      "--phase", "merged"
    )
    assert_equal 0, release.status.exitstatus, release.stderr

    reclaim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3979"
    )
    assert_equal 0, reclaim.status.exitstatus, reclaim.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3979.json")
    reclaimed_payload = JSON.parse(File.read(claim_path))
    assert_equal "active", reclaimed_payload.fetch("status")
    assert_equal "worker-a", reclaimed_payload.fetch("agent_id")
    assert_absent_lane_metadata(reclaimed_payload, "batch_id", "branch")
  end

  def test_claim_batch_change_does_not_preserve_old_lane_metadata
    first_claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3981",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "claimed")
    )
    assert_equal 0, first_claim.status.exitstatus, first_claim.stderr

    changed_lane = run_agent_coord(
      "claim",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3981",
      "--batch-id", "batch-2"
    )
    assert_equal 0, changed_lane.status.exitstatus, changed_lane.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3981.json")
    changed_payload = JSON.parse(File.read(claim_path))
    assert_equal "batch-2", changed_payload.fetch("batch_id")
    assert_absent_lane_metadata(changed_payload, "branch")
  end

  def test_plain_heartbeat_tick_preserves_lane_metadata
    first_heartbeat = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3975",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "validating")
    )
    assert_equal 0, first_heartbeat.status.exitstatus, first_heartbeat.stderr

    tick = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--status", "alive"
    )
    assert_equal 0, tick.status.exitstatus, tick.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/react_on_rails", heartbeat_payload.fetch("repo")
    assert_equal "3975", heartbeat_payload.fetch("target")
    assert_equal "batch-1", heartbeat_payload.fetch("batch_id")
    assert_equal "jg-codex/metadata", heartbeat_payload.fetch("branch")
    assert_equal "alive", heartbeat_payload.fetch("status")
    assert_lane_metadata(heartbeat_payload, phase: "validating")
  end

  def test_heartbeat_target_change_does_not_preserve_old_lane_metadata
    first_heartbeat = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3977",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "validating")
    )
    assert_equal 0, first_heartbeat.status.exitstatus, first_heartbeat.stderr

    retargeted = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/agent-workflows",
      "--target", "76",
      "--status", "validating"
    )
    assert_equal 0, retargeted.status.exitstatus, retargeted.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/agent-workflows", heartbeat_payload.fetch("repo")
    assert_equal "76", heartbeat_payload.fetch("target")
    assert_equal "validating", heartbeat_payload.fetch("status")
    assert_absent_lane_metadata(heartbeat_payload, "batch_id", "branch")
  end

  def test_heartbeat_batch_change_does_not_preserve_old_lane_metadata
    first_heartbeat = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3980",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "validating")
    )
    assert_equal 0, first_heartbeat.status.exitstatus, first_heartbeat.stderr

    retargeted = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3980",
      "--batch-id", "batch-2",
      "--status", "validating"
    )
    assert_equal 0, retargeted.status.exitstatus, retargeted.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/react_on_rails", heartbeat_payload.fetch("repo")
    assert_equal "3980", heartbeat_payload.fetch("target")
    assert_equal "batch-2", heartbeat_payload.fetch("batch_id")
    assert_equal "validating", heartbeat_payload.fetch("status")
    assert_absent_lane_metadata(heartbeat_payload, "branch")
  end

  def test_heartbeat_batch_change_without_target_args_preserves_repo_target
    first_heartbeat = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3982",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "validating")
    )
    assert_equal 0, first_heartbeat.status.exitstatus, first_heartbeat.stderr

    retargeted = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--batch-id", "batch-2",
      "--status", "validating"
    )
    assert_equal 0, retargeted.status.exitstatus, retargeted.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/react_on_rails", heartbeat_payload.fetch("repo")
    assert_equal "3982", heartbeat_payload.fetch("target")
    assert_equal "batch-2", heartbeat_payload.fetch("batch_id")
    assert_equal "validating", heartbeat_payload.fetch("status")
    assert_absent_lane_metadata(heartbeat_payload, "branch")
  end

  def test_heartbeat_repo_change_without_target_does_not_preserve_old_target
    first_heartbeat = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3983",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "validating")
    )
    assert_equal 0, first_heartbeat.status.exitstatus, first_heartbeat.stderr

    repo_only = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/agent-workflows",
      "--status", "validating"
    )
    assert_equal 0, repo_only.status.exitstatus, repo_only.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/agent-workflows", heartbeat_payload.fetch("repo")
    refute heartbeat_payload.key?("target"), "expected target to be absent"
    assert_equal "validating", heartbeat_payload.fetch("status")
    assert_absent_lane_metadata(heartbeat_payload, "batch_id", "branch")
  end

  def test_heartbeat_same_repo_without_target_clears_old_target
    first_heartbeat = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3984",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "validating")
    )
    assert_equal 0, first_heartbeat.status.exitstatus, first_heartbeat.stderr

    repo_only = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--status", "validating"
    )
    assert_equal 0, repo_only.status.exitstatus, repo_only.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/react_on_rails", heartbeat_payload.fetch("repo")
    refute heartbeat_payload.key?("target"), "expected target to be absent"
    assert_equal "validating", heartbeat_payload.fetch("status")
    assert_absent_lane_metadata(heartbeat_payload, "batch_id", "branch")
  end

  def test_heartbeat_adding_target_clears_repo_only_lane_metadata
    first_heartbeat = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/metadata",
      *lane_metadata_args(phase: "validating")
    )
    assert_equal 0, first_heartbeat.status.exitstatus, first_heartbeat.stderr

    target_specific = run_agent_coord(
      "heartbeat",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3985",
      "--status", "validating"
    )
    assert_equal 0, target_specific.status.exitstatus, target_specific.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/react_on_rails", heartbeat_payload.fetch("repo")
    assert_equal "3985", heartbeat_payload.fetch("target")
    assert_equal "validating", heartbeat_payload.fetch("status")
    assert_absent_lane_metadata(heartbeat_payload, "batch_id", "branch")
  end

  def test_concurrent_claims_for_same_item_have_exactly_one_winner
    results = %w[worker-a worker-b].map do |agent_id|
      Thread.new do
        run_agent_coord(
          "claim",
          "--agent-id", agent_id,
          "--repo", "shakacode/react_on_rails",
          "--target", "3971",
          "--batch-id", "batch-1",
          "--branch", "jg-codex/#{agent_id}",
          "--ttl", "3600"
        )
      end
    end.map(&:value)

    winners, losers = results.partition { |result| result.status.exitstatus.zero? }

    assert_equal 1, winners.length, results.map(&:stderr).join("\n")
    assert_equal 1, losers.length, results.map(&:stdout).join("\n")
    assert_match(/claim|state/, losers.first.stderr)

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3971.json")
    claim = JSON.parse(File.read(claim_path))
    assert_equal winners.first.stdout[/by (\S+) until/, 1], claim.fetch("agent_id")
  end

  def test_dead_heartbeat_allows_claim_takeover_before_claim_fallback_expires
    now = Time.now.utc
    write_claim(
      "3971",
      agent_id: "worker-a",
      updated_at: now - (30 * 60),
      expires_at: now + (4 * 60 * 60)
    )
    write_heartbeat(
      "worker-a",
      updated_at: now - (70 * 60),
      expires_at: now - (55 * 60)
    )

    takeover = run_agent_coord(
      "claim",
      "--agent-id", "worker-b",
      "--repo", "shakacode/react_on_rails",
      "--target", "3971",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/b",
      "--ttl", "3600"
    )

    assert_equal 0, takeover.status.exitstatus, takeover.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3971.json")
    claim = JSON.parse(File.read(claim_path))
    assert_equal "worker-b", claim.fetch("agent_id")
  end

  def test_live_and_stale_heartbeats_block_claim_takeover
    now = Time.now.utc
    cases = [
      ["3971-live", "worker-alpha", "live", now - (5 * 60), now + (10 * 60)],
      ["3971-stale", "worker-beta", "stale", now - (20 * 60), now - (5 * 60)]
    ]

    cases.each do |target, holder, expected_liveness, heartbeat_updated_at, heartbeat_expires_at|
      write_claim(
        target,
        agent_id: holder,
        updated_at: now - (30 * 60),
        expires_at: now + (4 * 60 * 60)
      )
      write_heartbeat(
        holder,
        updated_at: heartbeat_updated_at,
        expires_at: heartbeat_expires_at
      )

      competing_claim = run_agent_coord(
        "claim",
        "--agent-id", "worker-b",
        "--repo", "shakacode/react_on_rails",
        "--target", target,
        "--batch-id", "batch-1",
        "--branch", "jg-codex/b",
        "--ttl", "3600"
      )

      refute_equal 0, competing_claim.status.exitstatus
      assert_equal 3, competing_claim.status.exitstatus
      assert_includes competing_claim.stderr, holder
      assert_includes competing_claim.stderr, "heartbeat #{expected_liveness}"
    end
  end

  def test_missing_or_invalid_heartbeat_uses_claim_expiry_as_fallback
    now = Time.now.utc
    write_claim(
      "3971-missing",
      agent_id: "worker-missing",
      updated_at: now - (30 * 60),
      expires_at: now + (60 * 60)
    )

    missing_heartbeat_claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-b",
      "--repo", "shakacode/react_on_rails",
      "--target", "3971-missing",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/b",
      "--ttl", "3600"
    )

    refute_equal 0, missing_heartbeat_claim.status.exitstatus
    assert_equal 3, missing_heartbeat_claim.status.exitstatus
    assert_includes missing_heartbeat_claim.stderr, "heartbeat missing"

    write_claim(
      "3971-invalid",
      agent_id: "worker-invalid",
      updated_at: now - (2 * 60 * 60),
      expires_at: now - 60
    )
    FileUtils.mkdir_p(File.join(@state_root, "heartbeats"))
    File.write(File.join(@state_root, "heartbeats", "worker-invalid.json"), "{")

    invalid_heartbeat_claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-b",
      "--repo", "shakacode/react_on_rails",
      "--target", "3971-invalid",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/b",
      "--ttl", "3600"
    )

    assert_equal 0, invalid_heartbeat_claim.status.exitstatus, invalid_heartbeat_claim.stderr
  end

  def test_status_renders_batches_and_claims
    write_batch(
      "batch-1",
      lanes: [{ "name" => "backend", "targets" => ["3969"] }]
    )

    claim = run_agent_coord(
      "claim",
      "--agent-id", "worker-3969",
      "--repo", "shakacode/react_on_rails",
      "--target", "3969",
      "--batch-id", "batch-1",
      "--branch", "jg-codex/3969-agent-coord-backend",
      "--ttl", "3600"
    )

    assert_equal 0, claim.status.exitstatus, claim.stderr

    status = run_agent_coord("status")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes status.stdout, "claims"
    assert_includes status.stdout, "shakacode/react_on_rails#3969"
    assert_includes status.stdout, "branch jg-codex/3969-agent-coord-backend"
    assert_includes status.stdout, "batches"
    assert_includes status.stdout, "batch-1"
  end

  def test_status_target_scope_reads_only_claim_and_holder_heartbeat
    now = Time.utc(2026, 6, 20, 12, 0, 0)
    store = TargetScopedStore.new(now)
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    runner.define_singleton_method(:build_store) { |_options| store }

    result = runner.send(
      :render_status,
      repo: "shakacode/react_on_rails",
      target: "4150"
    )

    assert_equal 0, result
    assert_equal [
      "claims/shakacode/react_on_rails/4150.json",
      "heartbeats/worker-4150.json"
    ], store.reads
    assert_includes stdout.string, "shakacode/react_on_rails#4150"
    assert_includes stdout.string, "worker-4150 in_progress live"
    assert_includes stdout.string, "not checked in target scope"
  end

  def test_status_target_scope_json_reads_only_claim_and_holder_heartbeat
    now = Time.utc(2026, 6, 20, 12, 0, 0)
    store = TargetScopedStore.new(now)
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    runner.define_singleton_method(:build_store) { |_options| store }

    result = runner.send(
      :render_status,
      repo: "shakacode/react_on_rails",
      target: "4150",
      json: true
    )

    assert_equal 0, result
    assert_equal [
      "claims/shakacode/react_on_rails/4150.json",
      "heartbeats/worker-4150.json"
    ], store.reads

    payload = JSON.parse(stdout.string)
    assert_equal "target", payload.fetch("scope").fetch("kind")
    assert_equal "shakacode/react_on_rails", payload.fetch("scope").fetch("repo")
    assert_equal "4150", payload.fetch("scope").fetch("target")
    assert_equal ["not checked in target scope"], payload.fetch("degraded")
    assert_equal "not checked in target scope", payload.fetch("section_notes").fetch("batches")
    assert_equal "not checked in target scope", payload.fetch("section_notes").fetch("events")
    assert_equal "jg-codex/4150-worker", payload.fetch("claims").first.fetch("branch")
    assert_equal "worker-4150", payload.fetch("heartbeats").first.fetch("agent_id")
  end

  def test_status_target_scope_reports_malformed_claim_as_unknown
    claim_dir = File.join(@state_root, "claims", "shakacode", "react_on_rails")
    FileUtils.mkdir_p(claim_dir)
    File.write(File.join(claim_dir, "4150.json"), "{")

    status = run_agent_coord("status", "--repo", "shakacode/react_on_rails", "--target", "4150", "--json")

    assert_equal 2, status.status.exitstatus
    assert_empty status.stdout
    assert_includes status.stderr, "state unreadable"
  end

  def test_status_target_scope_reports_missing_holder_heartbeat
    now = Time.utc(2026, 6, 20, 12, 0, 0)
    store = MissingHeartbeatTargetStore.new(now)
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    runner.define_singleton_method(:build_store) { |_options| store }

    result = runner.send(
      :render_status,
      repo: "shakacode/react_on_rails",
      target: "4150",
      json: true
    )

    assert_equal 0, result
    payload = JSON.parse(stdout.string)
    assert_includes payload.fetch("degraded"), "holder heartbeat not found"
    assert_equal "holder heartbeat not found", payload.fetch("section_notes").fetch("heartbeats")
    assert_empty payload.fetch("heartbeats")
  end

  def test_status_target_scope_treats_invalid_holder_id_as_missing_heartbeat
    write_claim(
      "4150",
      agent_id: "bad/agent",
      updated_at: Time.now.utc - 60,
      expires_at: Time.now.utc + 3600
    )

    status = run_agent_coord("status", "--repo", "shakacode/react_on_rails", "--target", "4150", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    assert_equal "bad/agent", payload.fetch("claims").first.fetch("agent_id")
    assert_empty payload.fetch("heartbeats")
    assert_includes payload.fetch("degraded"), "holder heartbeat not found"
  end

  def test_status_target_scope_treats_unsafe_holder_id_as_missing_heartbeat
    write_claim(
      "4150",
      agent_id: "bad..agent",
      updated_at: Time.now.utc - 60,
      expires_at: Time.now.utc + 3600
    )

    status = run_agent_coord("status", "--repo", "shakacode/react_on_rails", "--target", "4150", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    assert_equal "bad..agent", payload.fetch("claims").first.fetch("agent_id")
    assert_empty payload.fetch("heartbeats")
    assert_includes payload.fetch("degraded"), "holder heartbeat not found"
  end

  def test_status_target_scope_propagates_unreadable_holder_heartbeat
    now = Time.utc(2026, 6, 20, 12, 0, 0)
    store = UnreadableHeartbeatTargetStore.new(now)
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    runner.define_singleton_method(:build_store) { |_options| store }

    assert_raises(AgentCoord::OperationalError) do
      runner.send(
        :render_status,
        repo: "shakacode/react_on_rails",
        target: "4150",
        json: true
      )
    end
  end

  def test_gh_result_does_not_treat_network_resolution_failure_as_not_found
    result = AgentCoord::GhResult.new(
      stdout: "",
      stderr: "could not resolve host: api.github.com",
      status: FakeStatus.new(false)
    )

    refute result.not_found?
  end

  def test_status_target_scope_reports_malformed_holder_heartbeat
    now = Time.now.utc
    write_claim("4150", agent_id: "worker-4150", updated_at: now - 60, expires_at: now + 3600)
    FileUtils.mkdir_p(File.join(@state_root, "heartbeats"))
    File.write(File.join(@state_root, "heartbeats", "worker-4150.json"), "{")

    status = run_agent_coord("status", "--repo", "shakacode/react_on_rails", "--target", "4150", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    assert_empty payload.fetch("heartbeats")
    assert_includes payload.fetch("degraded"), "holder heartbeat unreadable"
  end

  def test_status_target_scope_reports_missing_holder_on_claim
    claim_dir = File.join(@state_root, "claims", "shakacode", "react_on_rails")
    FileUtils.mkdir_p(claim_dir)
    File.write(
      File.join(claim_dir, "4150.json"),
      JSON.pretty_generate(
        "schema_version" => 1,
        "repo" => "shakacode/react_on_rails",
        "target" => "4150",
        "status" => "active",
        "claimed_at" => (Time.now.utc - 30).iso8601,
        "updated_at" => (Time.now.utc - 30).iso8601,
        "expires_at" => (Time.now.utc + 3600).iso8601
      )
    )

    status = run_agent_coord("status", "--repo", "shakacode/react_on_rails", "--target", "4150", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes JSON.parse(status.stdout).fetch("degraded"), "claim holder not set"
  end

  def test_status_target_scope_ignores_mismatched_holder_heartbeat_payload
    now = Time.now.utc
    write_claim("4150", agent_id: "worker-4150", updated_at: now - 60, expires_at: now + 3600)
    FileUtils.mkdir_p(File.join(@state_root, "heartbeats"))
    File.write(
      File.join(@state_root, "heartbeats", "worker-4150.json"),
      JSON.pretty_generate(
        "schema_version" => 1,
        "agent_id" => "other-worker",
        "status" => "done",
        "updated_at" => (now - 60).iso8601,
        "expires_at" => (now + 600).iso8601
      )
    )

    status = run_agent_coord("status", "--repo", "shakacode/react_on_rails", "--target", "4150", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    assert_empty payload.fetch("heartbeats")
    assert_includes payload.fetch("degraded"), "holder heartbeat mismatched"
  end

  def test_status_batch_scope_reports_missing_batch
    status = run_agent_coord("status", "--batch-id", "missing-batch", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    assert_includes payload.fetch("degraded"), "batch not found"
    assert_equal "batch not found", payload.fetch("section_notes").fetch("batches")
    assert_empty payload.fetch("batches")
  end

  def test_register_batch_writes_manifest_and_status_metadata
    manifest = {
      "batch_id" => "batch-b",
      "repo" => "shakacode/react_on_rails",
      "objective" => "Ship a low-risk batch",
      "launch_prompt" => "Coordinate the batch, then report the result.",
      "operator" => "justin",
      "dashboard_url" => "https://coord.example.test/batches/batch-b",
      "lanes" => [
        {
          "name" => "docs",
          "owner" => "worker-docs",
          "targets" => ["3972"],
          "depends_on" => [],
          "thread_handle" => "thread-docs",
          "host" => "m5",
          "pr_url" => "https://github.com/shakacode/react_on_rails/pull/3972",
          "dashboard_url" => "https://coord.example.test/batches/batch-b/docs"
        }
      ]
    }
    manifest_path = File.join(@state_root, "batch-manifest.json")
    File.write(manifest_path, JSON.pretty_generate(manifest))

    result = run_agent_coord("register-batch", "--file", manifest_path)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "registered batch batch-b"
    stored = JSON.parse(File.read(File.join(@state_root, "batches", "batch-b.json")))
    assert_equal 1, stored.fetch("schema_version")
    assert_equal "batch-b", stored.fetch("batch_id")
    assert_equal "Ship a low-risk batch", stored.fetch("objective")
    assert_equal "Coordinate the batch, then report the result.", stored.fetch("launch_prompt")
    assert_equal "justin", stored.fetch("operator")
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, stored.fetch("updated_at"))
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, stored.fetch("registered_at"))

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    batch = JSON.parse(status.stdout).fetch("batches").first
    assert_equal "shakacode/react_on_rails", batch.fetch("repo")
    assert_equal "Coordinate the batch, then report the result.", batch.fetch("launch_prompt")
    assert_equal "https://coord.example.test/batches/batch-b", batch.fetch("dashboard_url")
    lane = batch.fetch("lanes").first
    assert_equal "thread-docs", lane.fetch("thread_handle")
    assert_equal "m5", lane.fetch("host")
    assert_equal "https://github.com/shakacode/react_on_rails/pull/3972", lane.fetch("pr_url")
    assert_equal "https://coord.example.test/batches/batch-b/docs", lane.fetch("dashboard_url")
  end

  def test_record_event_writes_append_only_event_and_status_metadata
    write_batch(
      "batch-b",
      lanes: [{ "name" => "docs", "owner" => "worker-docs", "targets" => ["3972"] }]
    )

    result = run_agent_coord(
      "record-event",
      "--batch-id", "batch-b",
      "--type", "phase",
      "--lane", "docs",
      "--agent-id", "worker-docs",
      "--repo", "shakacode/react_on_rails",
      "--target", "3972",
      "--branch", "jg-codex/docs",
      "--phase", "validating",
      "--status", "in_progress",
      "--message", "running tests",
      "--thread-handle", "thread-docs",
      "--chat-handle", "codex-thread-123",
      "--host", "codex",
      "--operator", "justin",
      "--instance-id", "instance-a",
      "--generation", "3"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "recorded event batch-b"
    event_files = Dir.glob(File.join(@state_root, "events", "batch-b", "*.json"))
    assert_equal 1, event_files.length

    event = JSON.parse(File.read(event_files.first))
    assert_equal 1, event.fetch("schema_version")
    assert_equal "batch-b", event.fetch("batch_id")
    assert_equal "phase", event.fetch("type")
    assert_equal "docs", event.fetch("lane")
    assert_equal "worker-docs", event.fetch("agent_id")
    assert_equal "validating", event.fetch("phase")
    assert_equal "in_progress", event.fetch("status")
    assert_equal "running tests", event.fetch("message")
    assert_match(/\A\d{8}T\d{6}\.\d{6}Z-[0-9a-f]{8}\z/, event.fetch("event_id"))
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, event.fetch("at"))

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    status_event = JSON.parse(status.stdout).fetch("events").first
    assert_equal event.fetch("event_id"), status_event.fetch("event_id")
    assert_equal "phase", status_event.fetch("type")
    assert_equal "validating", status_event.fetch("phase")
    assert_equal "running tests", status_event.fetch("message")
  end

  def test_lane_closed_events_complete_batch_only_after_every_lane_is_terminal
    write_batch(
      "batch-close-events",
      lanes: [
        { "name" => "code", "owner" => "worker-a", "targets" => ["3981"] },
        { "name" => "docs", "owner" => "worker-b", "targets" => ["3982"] }
      ]
    )

    first = run_agent_coord(
      "record-event", "--batch-id", "batch-close-events", "--type", "lane_closed",
      "--lane", "code", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3981", "--host", "codex", "--terminal", "done"
    )
    assert_equal 0, first.status.exitstatus, first.stderr
    batch_path = File.join(@state_root, "batches", "batch-close-events.json")
    first_batch = JSON.parse(File.read(batch_path))
    refute first_batch.key?("status")
    assert_equal "done", first_batch.fetch("lanes").fetch(0).fetch("terminal")

    second = run_agent_coord(
      "record-event", "--batch-id", "batch-close-events", "--type", "lane_closed",
      "--lane", "docs", "--agent-id", "worker-b", "--repo", "shakacode/react_on_rails",
      "--target", "3982", "--host", "claude-code", "--terminal", "abandoned"
    )
    assert_equal 0, second.status.exitstatus, second.stderr
    completed = JSON.parse(File.read(batch_path))
    assert_equal "completed", completed.fetch("status")
    terminal_states = completed.fetch("lanes").map { |lane| lane.fetch("terminal") }
    assert_equal %w[done abandoned], terminal_states
  end

  def test_lane_closed_event_rejects_identity_that_does_not_match_registered_lane
    write_batch(
      "batch-identity",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3984"] }]
    )
    batch_path = File.join(@state_root, "batches", "batch-identity.json")
    batch = JSON.parse(File.read(batch_path)).merge("repo" => "shakacode/react_on_rails")
    File.write(batch_path, JSON.pretty_generate(batch))

    mismatches = [
      ["worker-a", "other/repo", "3984", "repo does not match"],
      ["worker-a", "shakacode/react_on_rails", "unrelated", "target does not match"],
      ["intruder", "shakacode/react_on_rails", "3984", "agent does not match"]
    ]
    mismatches.each do |agent_id, repo, target, message|
      result = run_agent_coord(
        "record-event", "--batch-id", "batch-identity", "--type", "lane_closed",
        "--lane", "code", "--agent-id", agent_id, "--repo", repo,
        "--target", target, "--terminal", "done"
      )
      assert_equal 1, result.status.exitstatus
      assert_includes result.stderr, message
    end

    refute_path_exists File.join(@state_root, "events", "batch-identity")
    persisted = JSON.parse(File.read(batch_path))
    refute persisted.fetch("lanes").fetch(0).key?("terminal")
  end

  def test_lane_closed_event_replay_is_idempotent_and_conflicts_are_sticky
    write_batch(
      "batch-sticky-event",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3989"] }]
    )
    args = [
      "record-event", "--batch-id", "batch-sticky-event", "--type", "lane_closed",
      "--lane", "code", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3989", "--host", "codex", "--terminal", "done",
      "--workspace", "team-a", "--pr-url", "https://github.com/shakacode/react_on_rails/pull/3989",
      "--pr-state", "merged", "--evidence-url", "https://example.test/evidence/3989"
    ]
    first = run_agent_coord(*args)
    assert_equal 0, first.status.exitstatus, first.stderr
    event_glob = File.join(@state_root, "events", "batch-sticky-event", "*.json")
    batch_path = File.join(@state_root, "batches", "batch-sticky-event.json")
    original_batch = File.read(batch_path)

    replay = run_agent_coord(*args)

    assert_equal 0, replay.status.exitstatus, replay.stderr
    assert_includes replay.stdout, "already closed"
    assert_equal 1, Dir.glob(event_glob).length
    assert_equal original_batch, File.read(batch_path)

    conflicts = {
      "--terminal" => "abandoned",
      "--workspace" => "team-b",
      "--host" => "claude-code",
      "--pr-url" => "https://github.com/shakacode/react_on_rails/pull/3990",
      "--pr-state" => "closed",
      "--evidence-url" => "https://example.test/evidence/different"
    }
    conflicts.each do |flag, value|
      conflicting = args.dup
      conflicting[conflicting.index(flag) + 1] = value
      conflict = run_agent_coord(*conflicting)
      assert_equal 1, conflict.status.exitstatus
      assert_includes conflict.stderr, "conflicting terminal closeout"
      assert_equal 1, Dir.glob(event_glob).length
      assert_equal original_batch, File.read(batch_path)
    end
  end

  def test_terminal_release_replay_is_idempotent_and_keeps_first_closeout
    write_batch(
      "batch-sticky-release",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3991"] }]
    )
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3991", "--batch-id", "batch-sticky-release", "--host", "codex"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr
    args = [
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3991", "--terminal", "done", "--workspace", "team-a",
      "--pr-url", "https://github.com/shakacode/react_on_rails/pull/3991",
      "--pr-state", "merged", "--evidence-url", "https://example.test/evidence/3991"
    ]
    first = run_agent_coord(*args)
    assert_equal 0, first.status.exitstatus, first.stderr
    event_glob = File.join(@state_root, "events", "batch-sticky-release", "*.json")
    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3991.json")
    batch_path = File.join(@state_root, "batches", "batch-sticky-release.json")
    originals = [File.read(claim_path), File.read(batch_path)]

    replay = run_agent_coord(*args)

    assert_equal 0, replay.status.exitstatus, replay.stderr
    assert_includes replay.stdout, "already closed"
    assert_equal 1, Dir.glob(event_glob).length
    assert_equal originals, [File.read(claim_path), File.read(batch_path)]

    conflicting = args.dup
    conflicting[conflicting.index("--evidence-url") + 1] = "https://example.test/evidence/replaced"
    conflict = run_agent_coord(*conflicting)

    assert_equal 1, conflict.status.exitstatus
    assert_includes conflict.stderr, "conflicting terminal closeout"
    assert_equal 1, Dir.glob(event_glob).length
    assert_equal originals, [File.read(claim_path), File.read(batch_path)]
  end

  def test_terminal_release_reconciles_claim_from_existing_authoritative_event
    write_batch(
      "batch-partial-release",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4012"] }]
    )
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "4012", "--batch-id", "batch-partial-release", "--host", "codex"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr
    close = run_agent_coord(
      "record-event", "--batch-id", "batch-partial-release", "--type", "lane_closed",
      "--lane", "code", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "4012", "--host", "codex", "--terminal", "done",
      "--pr-url", "https://github.com/shakacode/react_on_rails/pull/4012", "--pr-state", "merged"
    )
    assert_equal 0, close.status.exitstatus, close.stderr
    batch_path = File.join(@state_root, "batches", "batch-partial-release.json")
    authoritative_batch = File.read(batch_path)

    release = run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "4012", "--terminal", "done",
      "--pr-url", "https://github.com/shakacode/react_on_rails/pull/4012", "--pr-state", "merged"
    )

    assert_equal 0, release.status.exitstatus, release.stderr
    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "4012.json")
    claim_payload = JSON.parse(File.read(claim_path))
    assert_equal "released", claim_payload.fetch("status")
    assert_equal "done", claim_payload.fetch("terminal")
    assert_equal "default", claim_payload.fetch("workspace")
    assert_equal({ "agent_id" => "worker-a", "machine" => "codex" }, claim_payload.fetch("closed_by"))
    assert_equal 1, Dir.glob(File.join(@state_root, "events", "batch-partial-release", "*.json")).length
    assert_equal authoritative_batch, File.read(batch_path)
  end

  def test_concurrent_identical_terminal_releases_converge_same_claim
    write_batch("batch-same-claim", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4013"] }])
    claim = run_agent_coord("claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
                            "--target", "4013", "--batch-id", "batch-same-claim", "--host", "codex")
    assert_equal 0, claim.status.exitstatus, claim.stderr
    store = ConcurrentClaimReleaseStore.new(@state_root, "shakacode/react_on_rails", "4013")
    results = []
    errors = []
    threads = 2.times.map do
      Thread.new do
        runner = StoreInjectedRunner.new(
          ["release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4013",
           "--terminal", "done"], store: store
        )
        results << runner.run
      rescue AgentCoord::Error => e
        errors << e
      end
    end
    threads.each(&:join)

    assert_empty errors
    assert_equal [0, 0], results.sort
    assert_equal 1, Dir.glob(File.join(@state_root, "events", "batch-same-claim", "*.json")).length
    claim_payload = JSON.parse(File.read(File.join(@state_root, "claims", "shakacode", "react_on_rails", "4013.json")))
    assert_equal "released", claim_payload.fetch("status")
    batch = JSON.parse(File.read(File.join(@state_root, "batches", "batch-same-claim.json")))
    assert_equal "done", batch.fetch("lanes").fetch(0).fetch("terminal")
  end

  def test_record_event_rejects_malformed_lane_names
    result = run_agent_coord(
      "record-event",
      "--batch-id", "batch-b",
      "--type", "phase",
      "--lane", "docs:copy"
    )

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "event lane docs:copy cannot contain ':'"
    refute_path_exists File.join(@state_root, "events", "batch-b")
  end

  def test_terminal_only_flags_are_rejected_outside_terminal_closeout
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3986", "--terminal", "done"
    )
    assert_equal 1, claim.status.exitstatus
    assert_includes claim.stderr, "--terminal is only valid"

    event = run_agent_coord(
      "record-event", "--batch-id", "batch-b", "--type", "phase", "--terminal", "done"
    )
    assert_equal 1, event.status.exitstatus
    assert_includes event.stderr, "terminal-only options require --type lane_closed"

    normal_release = run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3986", "--pr-state", "merged"
    )
    assert_equal 1, normal_release.status.exitstatus
    assert_includes normal_release.stderr, "--pr-state requires --terminal"
  end

  def test_lane_closed_rejects_schema_invalid_fields_before_writing
    invalid_cases = [
      ["workspace", ["--workspace", ""]],
      ["pr-url", ["--pr-url", "not a uri"]],
      ["evidence-url", ["--evidence-url", "://bad"]],
      ["pr-url", ["--pr-url", "javascript:alert(1)"]],
      ["evidence-url", ["--evidence-url", "data:text/plain,bad"]]
    ]
    invalid_cases.each_with_index do |(field, invalid_args), index|
      batch_id = "batch-invalid-close-#{index}"
      target = (4000 + index).to_s
      write_batch(
        batch_id,
        lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => [target] }]
      )
      batch_path = File.join(@state_root, "batches", "#{batch_id}.json")
      original_batch = File.read(batch_path)
      result = run_agent_coord(
        "record-event", "--batch-id", batch_id, "--type", "lane_closed",
        "--lane", "code", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
        "--target", target, "--host", "codex", "--terminal", "done", *invalid_args
      )

      assert_equal 1, result.status.exitstatus
      assert_includes result.stderr, "--#{field}"
      assert_includes result.stderr, "must be an HTTP(S) URL with a host" unless field == "workspace"
      refute_path_exists File.join(@state_root, "events", batch_id)
      assert_equal original_batch, File.read(batch_path)
    end
  end

  def test_record_event_accepts_registered_lane_name_characters
    result = run_agent_coord(
      "record-event",
      "--batch-id", "batch-b",
      "--type", "phase",
      "--lane", "docs/api copy"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    event = JSON.parse(File.read(Dir.glob(File.join(@state_root, "events", "batch-b", "*.json")).first))
    assert_equal "docs/api copy", event.fetch("lane")
  end

  def test_register_batch_rejects_malformed_lane_name
    manifest_path = File.join(@state_root, "batch-manifest.json")
    File.write(
      manifest_path,
      JSON.pretty_generate(
        "batch_id" => "batch-b",
        "lanes" => [
          { "name" => "docs:copy", "owner" => "worker-docs", "targets" => ["3972"] }
        ]
      )
    )

    result = run_agent_coord("register-batch", "--file", manifest_path)

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "batch lane docs:copy cannot contain ':'"
    refute_path_exists File.join(@state_root, "batches", "batch-b.json")
  end

  def test_register_batch_rejects_duplicate_lane_names
    manifest_path = File.join(@state_root, "batch-manifest.json")
    File.write(
      manifest_path,
      JSON.pretty_generate(
        "batch_id" => "batch-b",
        "lanes" => [
          { "name" => "docs", "owner" => "worker-docs-a", "targets" => ["3972"] },
          { "name" => "docs", "owner" => "worker-docs-b", "targets" => ["3973"] }
        ]
      )
    )

    result = run_agent_coord("register-batch", "--file", manifest_path)

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "batch lane docs is duplicated"
    refute_path_exists File.join(@state_root, "batches", "batch-b.json")
  end

  def test_register_batch_rejects_non_string_repo_without_backtrace
    manifest_path = File.join(@state_root, "batch-manifest.json")
    File.write(
      manifest_path,
      JSON.pretty_generate(
        "batch_id" => "batch-b",
        "repo" => 12_345,
        "lanes" => [
          { "name" => "docs", "owner" => "worker-docs", "targets" => ["3972"] }
        ]
      )
    )

    result = run_agent_coord("register-batch", "--file", manifest_path)

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "invalid batch repo: 12345"
    refute_includes result.stderr, "NoMethodError"
    refute_path_exists File.join(@state_root, "batches", "batch-b.json")
  end

  def test_register_batch_rejects_non_string_lane_name
    manifest_path = File.join(@state_root, "batch-manifest.json")
    File.write(
      manifest_path,
      JSON.pretty_generate(
        "batch_id" => "batch-b",
        "lanes" => [
          { "name" => 1, "owner" => "worker-docs", "targets" => ["3972"] }
        ]
      )
    )

    result = run_agent_coord("register-batch", "--file", manifest_path)

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "batch lane 1 name must be a string"
    refute_path_exists File.join(@state_root, "batches", "batch-b.json")
  end

  def test_status_batch_scope_reports_missing_lane_owner_heartbeats
    write_batch(
      "batch-b",
      lanes: [{ "name" => "docs", "owner" => "worker-docs", "targets" => ["3972"] }]
    )

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    assert_includes payload.fetch("degraded"), "lane-owner heartbeats not found: worker-docs"
    assert_equal "lane-owner heartbeats not found: worker-docs", payload.fetch("section_notes").fetch("heartbeats")
    assert_empty payload.fetch("heartbeats")
  end

  def test_status_batch_scope_reports_unknown_lane_owner_heartbeat_as_missing
    write_batch("batch-b", lanes: [{ "name" => "docs", "targets" => ["3972"] }])

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes JSON.parse(status.stdout).fetch("degraded"), "lane-owner heartbeats not found: UNKNOWN"
  end

  def test_status_batch_scope_reports_empty_lane_owner_heartbeat_as_unknown
    write_batch("batch-b", lanes: [{ "name" => "docs", "owner" => "", "targets" => ["3972"] }])

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes JSON.parse(status.stdout).fetch("degraded"), "lane-owner heartbeats not found: UNKNOWN"
  end

  def test_status_batch_scope_handles_non_object_lanes_as_degraded
    write_batch("batch-b", lanes: ["stray-lane"])

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    lane = payload.fetch("batches").first.fetch("lanes").first
    assert_equal "UNKNOWN", lane.fetch("name")
    assert_equal "UNKNOWN", lane.fetch("owner")
    assert_includes payload.fetch("degraded"), "lane-owner heartbeats not found: UNKNOWN"
  end

  def test_status_batch_scope_reports_malformed_batch_as_unknown
    FileUtils.mkdir_p(File.join(@state_root, "batches"))
    File.write(File.join(@state_root, "batches", "batch-b.json"), "{")

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 2, status.status.exitstatus
    assert_empty status.stdout
    assert_includes status.stderr, "state unreadable"
  end

  def test_status_batch_scope_reports_malformed_lane_owner_heartbeat
    write_batch(
      "batch-b",
      lanes: [{ "name" => "docs", "owner" => "worker-docs", "targets" => ["3972"] }]
    )
    FileUtils.mkdir_p(File.join(@state_root, "heartbeats"))
    File.write(File.join(@state_root, "heartbeats", "worker-docs.json"), "{")

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    lane = payload.fetch("batches").first.fetch("lanes").first
    assert_equal "unreadable", lane.fetch("liveness")
    assert_empty payload.fetch("heartbeats")
    assert_includes payload.fetch("degraded"), "lane-owner heartbeats unreadable: worker-docs"
  end

  def test_status_batch_scope_ignores_mismatched_lane_owner_heartbeat_payload
    now = Time.now.utc
    write_batch(
      "batch-b",
      lanes: [{ "name" => "docs", "owner" => "worker-docs", "targets" => ["3972"] }]
    )
    FileUtils.mkdir_p(File.join(@state_root, "heartbeats"))
    File.write(
      File.join(@state_root, "heartbeats", "worker-docs.json"),
      JSON.pretty_generate(
        "schema_version" => 1,
        "agent_id" => "other-worker",
        "status" => "done",
        "updated_at" => (now - 60).iso8601,
        "expires_at" => (now + 600).iso8601
      )
    )

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    lane = payload.fetch("batches").first.fetch("lanes").first
    assert_equal "mismatched", lane.fetch("liveness")
    assert_empty payload.fetch("heartbeats")
    assert_includes payload.fetch("degraded"), "lane-owner heartbeats mismatched: worker-docs"
  end

  def test_status_text_renders_degraded_footer_when_sections_have_rows
    now = Time.now.utc
    write_batch(
      "batch-b",
      lanes: [
        { "name" => "docs", "owner" => "worker-docs", "targets" => ["3972"] },
        { "name" => "qa", "owner" => "worker-qa", "targets" => ["3973"] }
      ]
    )
    write_heartbeat(
      "worker-docs",
      status: "done",
      updated_at: now - 60,
      expires_at: now + 600
    )

    status = run_agent_coord("status", "--batch-id", "batch-b")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes status.stdout, "- worker-docs done live - updated"
    assert_includes status.stdout,
                    "degraded\n- not checked in batch scope\n- lane-owner heartbeats not found: worker-qa"
  end

  def test_status_batch_scope_reads_only_batch_dependencies_and_lane_heartbeats
    now = Time.utc(2026, 6, 20, 12, 0, 0)
    store = BatchScopedStore.new(now)
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    runner.define_singleton_method(:build_store) { |_options| store }

    result = runner.send(:render_status, batch_id: "batch-b")

    assert_equal 0, result
    assert_equal [
      "batches/batch-b.json",
      "events/batch-b",
      "heartbeats/worker-docs.json",
      "batches/batch-a.json",
      "heartbeats/worker-backend.json"
    ], store.reads
    assert_includes stdout.string, "lane docs owner worker-docs targets 4150 status blocked live"
    assert_includes stdout.string, "deps batch-a:backend blocked_on -"
    assert_includes stdout.string, "not checked in batch scope"
  end

  def test_status_renders_lane_dependencies_and_blocked_lanes
    now = Time.now.utc
    write_batch(
      "batch-1",
      lanes: [
        { "name" => "backend", "owner" => "worker-backend", "targets" => ["3970"] },
        {
          "name" => "docs",
          "owner" => "worker-docs",
          "targets" => ["3972"],
          "depends_on" => ["batch-1:backend"]
        }
      ]
    )
    write_heartbeat(
      "worker-backend",
      status: "in_progress",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )
    write_heartbeat(
      "worker-docs",
      status: "blocked",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )

    status = run_agent_coord("status")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes status.stdout, "lane backend owner worker-backend targets 3970 status in_progress live"
    assert_includes status.stdout, "deps - blocked_on -"
    assert_includes status.stdout, "lane docs owner worker-docs targets 3972 status blocked live"
    assert_includes status.stdout, "deps batch-1:backend blocked_on batch-1:backend"
  end

  def test_status_resolves_dependencies_across_batches
    now = Time.now.utc
    write_batch(
      "batch-a",
      lanes: [{ "name" => "backend", "owner" => "worker-backend", "targets" => ["3970"] }]
    )
    write_batch(
      "batch-b",
      lanes: [
        {
          "name" => "docs",
          "owner" => "worker-docs",
          "targets" => ["3972"],
          "depends_on" => ["batch-a:backend"]
        }
      ]
    )
    write_heartbeat(
      "worker-backend",
      status: "done",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )
    write_heartbeat(
      "worker-docs",
      status: "blocked",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )

    status = run_agent_coord("status")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes status.stdout, "lane docs owner worker-docs targets 3972 status blocked live"
    assert_includes status.stdout, "deps batch-a:backend blocked_on -"
  end

  def test_status_batch_scope_resolves_dependency_batch_ids_with_colons
    now = Time.now.utc
    write_batch(
      "batch:a",
      lanes: [{ "name" => "backend", "owner" => "worker-backend", "targets" => ["3970"] }]
    )
    write_batch(
      "batch:b",
      lanes: [
        {
          "name" => "docs",
          "owner" => "worker-docs",
          "targets" => ["3972"],
          "depends_on" => ["batch:a:backend"]
        }
      ]
    )
    write_heartbeat(
      "worker-backend",
      status: "done",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )
    write_heartbeat(
      "worker-docs",
      status: "blocked",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )

    status = run_agent_coord("status", "--batch-id", "batch:b")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes status.stdout, "lane docs owner worker-docs targets 3972 status blocked live"
    assert_includes status.stdout, "deps batch:a:backend blocked_on -"
  end

  def test_status_batch_scope_reports_lane_names_with_colons_as_malformed
    write_batch(
      "batch-b",
      lanes: [{ "name" => "feature:login", "owner" => "worker-feature", "targets" => ["3970"] }]
    )

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes JSON.parse(status.stdout).fetch("degraded"), "malformed lane names: feature:login"
  end

  def test_status_broad_scope_reports_lane_names_with_colons_as_malformed
    write_batch(
      "batch-b",
      lanes: [{ "name" => "feature:login", "owner" => "worker-feature", "targets" => ["3970"] }]
    )

    status = run_agent_coord("status", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes JSON.parse(status.stdout).fetch("degraded"), "malformed lane names: feature:login"
  end

  def test_status_batch_scope_treats_malformed_dependency_ref_as_unmet
    write_batch(
      "batch-b",
      lanes: [
        {
          "name" => "docs",
          "owner" => "worker-docs",
          "targets" => ["3972"],
          "depends_on" => ["bad/batch:backend"]
        }
      ]
    )
    write_heartbeat(
      "worker-docs",
      status: "blocked",
      updated_at: Time.now.utc - (5 * 60),
      expires_at: Time.now.utc + (10 * 60)
    )

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    lane = JSON.parse(status.stdout).fetch("batches").first.fetch("lanes").first
    assert_equal ["bad/batch:backend"], lane.fetch("deps")
    assert_equal ["bad/batch:backend"], lane.fetch("blocked_on")
    assert_includes JSON.parse(status.stdout).fetch("degraded"), "malformed dependency refs: bad/batch:backend"
  end

  def test_status_batch_scope_reports_bare_dependency_ref_as_malformed
    write_batch(
      "batch-b",
      lanes: [
        {
          "name" => "docs",
          "owner" => "worker-docs",
          "targets" => ["3972"],
          "depends_on" => ["backend"]
        }
      ]
    )
    write_heartbeat(
      "worker-docs",
      status: "blocked",
      updated_at: Time.now.utc - (5 * 60),
      expires_at: Time.now.utc + (10 * 60)
    )

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    assert_includes payload.fetch("degraded"), "malformed dependency refs: backend"
    lane = payload.fetch("batches").first.fetch("lanes").first
    assert_equal ["backend"], lane.fetch("blocked_on")
  end

  def test_status_batch_scope_reports_missing_dependency_lane
    write_batch(
      "batch-a",
      lanes: [{ "name" => "backend", "owner" => "worker-backend", "targets" => ["3970"] }]
    )
    write_batch(
      "batch-b",
      lanes: [
        {
          "name" => "docs",
          "owner" => "worker-docs",
          "targets" => ["3972"],
          "depends_on" => ["batch-a:missing"]
        }
      ]
    )

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    assert_includes payload.fetch("degraded"), "malformed dependency refs: batch-a:missing"
    lane = payload.fetch("batches").first.fetch("lanes").first
    assert_equal ["batch-a:missing"], lane.fetch("blocked_on")
  end

  def test_status_batch_scope_treats_unsafe_dependency_ref_as_unmet
    write_batch(
      "batch-b",
      lanes: [
        {
          "name" => "docs",
          "owner" => "worker-docs",
          "targets" => ["3972"],
          "depends_on" => ["bad..batch:backend"]
        }
      ]
    )
    write_heartbeat(
      "worker-docs",
      status: "blocked",
      updated_at: Time.now.utc - (5 * 60),
      expires_at: Time.now.utc + (10 * 60)
    )

    status = run_agent_coord("status", "--batch-id", "batch-b", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    payload = JSON.parse(status.stdout)
    lane = payload.fetch("batches").first.fetch("lanes").first
    assert_equal ["bad..batch:backend"], lane.fetch("deps")
    assert_equal ["bad..batch:backend"], lane.fetch("blocked_on")
    assert_includes payload.fetch("degraded"), "malformed dependency refs: bad..batch:backend"
  end

  def test_released_dependency_does_not_unblock_lane
    now = Time.now.utc
    write_batch(
      "batch-a",
      lanes: [{ "name" => "backend", "owner" => "worker-backend", "targets" => ["3970"] }]
    )
    write_batch(
      "batch-b",
      lanes: [
        {
          "name" => "docs",
          "owner" => "worker-docs",
          "targets" => ["3972"],
          "depends_on" => ["batch-a:backend"]
        }
      ]
    )
    write_heartbeat(
      "worker-backend",
      status: "released",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )
    write_heartbeat(
      "worker-docs",
      status: "blocked",
      updated_at: now - (5 * 60),
      expires_at: now + (10 * 60)
    )

    status = run_agent_coord("status")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes status.stdout, "lane docs owner worker-docs targets 3972 status blocked live"
    assert_includes status.stdout, "deps batch-a:backend blocked_on batch-a:backend"
  end

  CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true)
  COMMAND_ENV = {
    "AGENT_COORD_API_TOKEN" => nil,
    "AGENT_COORD_API_URL" => nil,
    "AGENT_COORD_BACKEND" => nil,
    "AGENT_COORD_STATE_ROOT" => nil,
    "AGENT_COORD_STATUS_STATE_ROOT" => nil
  }.freeze

  FixedClock = Struct.new(:time) do
    def now
      time
    end
  end

  class NoBroadScanStore
    attr_reader :reads

    def initialize
      @reads = []
    end

    def list_json(prefix)
      raise "unexpected broad scan of #{prefix}"
    end

    private

    def stored(path, data)
      @reads << path
      AgentCoord::StoredJson.new(path: path, data: data, sha: "sha-#{@reads.length}")
    end
  end

  class TargetScopedStore < NoBroadScanStore
    def initialize(now)
      super()
      @now = now
    end

    def read_json(path)
      case path
      when "claims/shakacode/react_on_rails/4150.json"
        stored(
          path,
          "schema_version" => 1,
          "repo" => "shakacode/react_on_rails",
          "target" => "4150",
          "agent_id" => "worker-4150",
          "branch" => "jg-codex/4150-worker",
          "status" => "active",
          "claimed_at" => (@now - 60).iso8601,
          "updated_at" => (@now - 60).iso8601,
          "expires_at" => (@now + 3600).iso8601
        )
      when "heartbeats/worker-4150.json"
        stored(
          path,
          "schema_version" => 1,
          "agent_id" => "worker-4150",
          "repo" => "shakacode/react_on_rails",
          "target" => "4150",
          "status" => "in_progress",
          "updated_at" => (@now - 60).iso8601,
          "expires_at" => (@now + 600).iso8601
        )
      else
        raise AgentCoord::OperationalError, "unexpected read #{path}"
      end
    end
  end

  class MissingHeartbeatTargetStore < TargetScopedStore
    def read_json(path)
      return nil if path == "heartbeats/worker-4150.json"

      super
    end
  end

  class UnreadableHeartbeatTargetStore < TargetScopedStore
    def read_json(path)
      raise AgentCoord::OperationalError, "gh api failed" if path == "heartbeats/worker-4150.json"

      super
    end
  end

  class BatchScopedStore < NoBroadScanStore
    def initialize(now)
      super()
      @now = now
    end

    # rubocop:disable Metrics/MethodLength
    def read_json(path)
      case path
      when "batches/batch-b.json"
        stored(
          path,
          "schema_version" => 1,
          "batch_id" => "batch-b",
          "lanes" => [
            {
              "name" => "docs",
              "owner" => "worker-docs",
              "targets" => ["4150"],
              "depends_on" => ["batch-a:backend"]
            }
          ],
          "updated_at" => @now.iso8601
        )
      when "batches/batch-a.json"
        stored(
          path,
          "schema_version" => 1,
          "batch_id" => "batch-a",
          "lanes" => [
            { "name" => "backend", "owner" => "worker-backend", "targets" => ["4144"] }
          ],
          "updated_at" => @now.iso8601
        )
      when "heartbeats/worker-docs.json"
        stored(
          path,
          "schema_version" => 1,
          "agent_id" => "worker-docs",
          "status" => "blocked",
          "updated_at" => (@now - 60).iso8601,
          "expires_at" => (@now + 600).iso8601
        )
      when "heartbeats/worker-backend.json"
        stored(
          path,
          "schema_version" => 1,
          "agent_id" => "worker-backend",
          "status" => "done",
          "updated_at" => (@now - 60).iso8601,
          "expires_at" => (@now + 600).iso8601
        )
      else
        raise AgentCoord::OperationalError, "unexpected read #{path}"
      end
    end
    # rubocop:enable Metrics/MethodLength

    def list_json(prefix)
      raise "unexpected broad scan of #{prefix}" unless prefix == "events/batch-b"

      @reads << prefix
      []
    end
  end

  FakeStatus = Struct.new(:successful) do
    def success?
      successful
    end
  end

  class StoreInjectedRunner < AgentCoord::Runner
    def initialize(argv, store:)
      @injected_store = store
      super(argv, stdout: StringIO.new, stderr: StringIO.new)
    end

    private

    def build_store(_options)
      @injected_store
    end

    def close_store(_store); end
  end

  class ConcurrentBatchStore < AgentCoord::LocalStore
    def initialize(root, batch_id)
      super(root)
      @batch_path = AgentCoord.batch_path(batch_id)
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @batch_reads = Hash.new(0)
      @waiting = 0
    end

    def read_json(path)
      entry = super
      synchronize_second_batch_read if path == @batch_path
      entry
    end

    private

    def synchronize_second_batch_read
      thread_id = Thread.current.object_id
      @mutex.synchronize do
        @batch_reads[thread_id] += 1
        return unless @batch_reads[thread_id] == 2

        @waiting += 1
        if @waiting == 2
          @condition.broadcast
        else
          @condition.wait(@mutex) until @waiting == 2
        end
      end
    end
  end

  class ConcurrentTerminalEventStore < AgentCoord::LocalStore
    def initialize(root, batch_id)
      super(root)
      @event_prefix = "#{AgentCoord.event_batch_prefix(batch_id)}/"
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @waiting = 0
    end

    def write_json(path, data, message:, sha: nil, create: false)
      synchronize_terminal_create if create && path.start_with?(@event_prefix)
      super
    end

    private

    def synchronize_terminal_create
      @mutex.synchronize do
        @waiting += 1
        if @waiting == 2
          @condition.broadcast
        else
          @condition.wait(@mutex) until @waiting == 2
        end
      end
    end
  end

  class ConcurrentClaimReleaseStore < AgentCoord::LocalStore
    def initialize(root, repo, target)
      super(root)
      @claim_path = AgentCoord.claim_path(repo, target)
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @waiting = 0
    end

    def write_json(path, data, message:, sha: nil, create: false)
      synchronize_release if path == @claim_path && data["status"] == "released"
      super
    end

    private

    def synchronize_release
      @mutex.synchronize do
        @waiting += 1
        @waiting == 2 ? @condition.broadcast : @condition.wait(@mutex) { @waiting == 2 }
      end
    end
  end

  class ConflictCachingGitHubStore < AgentCoord::GitHubStore
    def initialize
      super(backend: "shakacode/agent-coordination-state", ref: "state")
      @content_reads = 0
    end

    private

    def gh_api(*args)
      worker_a_path = %r{\Arepos/shakacode/agent-coordination-state/contents/heartbeats/worker-a\.json\?ref=state\z}
      if args.length == 1 && args.first.match?(worker_a_path)
        @content_reads += 1
        status = @content_reads == 1 ? "old" : "new"
        sha = @content_reads == 1 ? "sha-old" : "sha-new"
        return result(
          JSON.generate(
            "content" => Base64.strict_encode64(JSON.generate("status" => status)),
            "sha" => sha
          )
        )
      end

      if args.include?("repos/shakacode/agent-coordination-state/contents/heartbeats/worker-a.json")
        return result("", stderr: "409 conflict", success: false)
      end

      raise "unexpected gh api #{args.inspect}"
    end

    def result(stdout, stderr: "", success: true)
      AgentCoord::GhResult.new(stdout: stdout, stderr: stderr, status: FakeStatus.new(success))
    end
  end

  class MissingContentVerifiesRefGitHubStore < AgentCoord::GitHubStore
    attr_reader :ref_reads

    def initialize
      super(backend: "shakacode/agent-coordination-state", ref: "state")
      @ref_reads = 0
    end

    private

    def gh_api(*args)
      case args
      when ["repos/shakacode/agent-coordination-state/contents/claims/shakacode/react_on_rails/4150.json?ref=state"]
        result("", stderr: "Not Found", success: false)
      when ["repos/shakacode/agent-coordination-state/git/trees/state"]
        @ref_reads += 1
        result(JSON.generate("tree" => []))
      else
        raise "unexpected gh api #{args.inspect}"
      end
    end

    def result(stdout, stderr: "", success: true)
      AgentCoord::GhResult.new(stdout: stdout, stderr: stderr, status: FakeStatus.new(success))
    end
  end

  class MissingContentUnreadableRefGitHubStore < AgentCoord::GitHubStore
    def initialize
      super(backend: "shakacode/agent-coordination-state", ref: "missing-ref")
    end

    private

    def gh_api(*args)
      case args
      when [
        "repos/shakacode/agent-coordination-state/contents/claims/" \
        "shakacode/react_on_rails/4150.json?ref=missing-ref"
      ],
           ["repos/shakacode/agent-coordination-state/git/trees/missing-ref"]
        result("", stderr: "Not Found", success: false)
      else
        raise "unexpected gh api #{args.inspect}"
      end
    end

    def result(stdout, stderr: "", success: true)
      AgentCoord::GhResult.new(stdout: stdout, stderr: stderr, status: FakeStatus.new(success))
    end
  end

  class ConflictTreeCachingGitHubStore < AgentCoord::GitHubStore
    attr_reader :tree_reads

    def initialize
      super(backend: "shakacode/agent-coordination-state", ref: "state")
      @content_reads = 0
      @tree_reads = 0
      @created_elsewhere = false
    end

    private

    def gh_api(*args)
      case args
      when ["repos/shakacode/agent-coordination-state/git/trees/state?recursive=1"]
        @tree_reads += 1
        tree = [{ "path" => "heartbeats/worker-a.json", "type" => "blob" }]
        tree << { "path" => "heartbeats/worker-b.json", "type" => "blob" } if @created_elsewhere
        result(JSON.generate("tree" => tree))
      when ["repos/shakacode/agent-coordination-state/contents/heartbeats/worker-a.json?ref=state"]
        @content_reads += 1
        status = @content_reads == 1 ? "old" : "new"
        sha = @content_reads == 1 ? "sha-old" : "sha-new"
        result(
          JSON.generate(
            "content" => Base64.strict_encode64(JSON.generate("status" => status)),
            "sha" => sha
          )
        )
      when ["repos/shakacode/agent-coordination-state/contents/heartbeats/worker-b.json?ref=state"]
        result(
          JSON.generate(
            "content" => Base64.strict_encode64(JSON.generate("status" => "created-elsewhere")),
            "sha" => "sha-worker-b"
          )
        )
      else
        if args.include?("repos/shakacode/agent-coordination-state/contents/heartbeats/worker-a.json")
          @created_elsewhere = true
          return result("", stderr: "409 conflict", success: false)
        end

        raise "unexpected gh api #{args.inspect}"
      end
    end

    def result(stdout, stderr: "", success: true)
      AgentCoord::GhResult.new(stdout: stdout, stderr: stderr, status: FakeStatus.new(success))
    end
  end

  class CreateConflictTreeInvalidationGitHubStore < AgentCoord::GitHubStore
    attr_reader :tree_reads

    def initialize
      super(backend: "shakacode/agent-coordination-state", ref: "state")
      @tree_reads = 0
      @created_elsewhere = false
    end

    private

    def gh_api(*args)
      case args
      when ["repos/shakacode/agent-coordination-state/git/trees/state?recursive=1"]
        @tree_reads += 1
        tree = @created_elsewhere ? [{ "path" => "heartbeats/worker-a.json", "type" => "blob" }] : []
        result(JSON.generate("tree" => tree))
      when ["repos/shakacode/agent-coordination-state/contents/heartbeats/worker-a.json?ref=state"]
        result(
          JSON.generate(
            "content" => Base64.strict_encode64(JSON.generate("status" => "theirs")),
            "sha" => "sha-theirs"
          )
        )
      else
        if args.include?("repos/shakacode/agent-coordination-state/contents/heartbeats/worker-a.json")
          @created_elsewhere = true
          return result("", stderr: "409 conflict", success: false)
        end

        raise "unexpected gh api #{args.inspect}"
      end
    end

    def result(stdout, stderr: "", success: true)
      AgentCoord::GhResult.new(stdout: stdout, stderr: stderr, status: FakeStatus.new(success))
    end
  end

  class TreeInvalidationGitHubStore < AgentCoord::GitHubStore
    attr_reader :tree_reads

    def initialize
      super(backend: "shakacode/agent-coordination-state", ref: "state")
      @tree_reads = 0
      @written = false
    end

    private

    def gh_api(*args)
      case args
      when ["repos/shakacode/agent-coordination-state/git/trees/state?recursive=1"]
        @tree_reads += 1
        tree = @written ? [{ "path" => "claims/shakacode/react_on_rails/4150.json", "type" => "blob" }] : []
        result(JSON.generate("tree" => tree))
      when ["repos/shakacode/agent-coordination-state/contents/claims/shakacode/react_on_rails/4150.json?ref=state"]
        result(
          JSON.generate(
            "content" => Base64.strict_encode64(JSON.generate("status" => "active")),
            "sha" => "sha-claim"
          )
        )
      else
        if args.include?("repos/shakacode/agent-coordination-state/contents/claims/shakacode/react_on_rails/4150.json")
          @written = true
          return result(JSON.generate("content" => { "sha" => "sha-claim" }))
        end

        raise "unexpected gh api #{args.inspect}"
      end
    end

    def result(stdout, stderr: "", success: true)
      AgentCoord::GhResult.new(stdout: stdout, stderr: stderr, status: FakeStatus.new(success))
    end
  end

  class BlobPrefixLayoutGitHubStore < AgentCoord::GitHubStore
    def initialize
      super(backend: "shakacode/agent-coordination-state", ref: "state")
    end

    private

    def gh_api(*args)
      if args == ["repos/shakacode/agent-coordination-state/git/trees/state?recursive=1"]
        return AgentCoord::GhResult.new(
          stdout: JSON.generate(
            "tree" => [
              { "path" => "claims", "type" => "blob" },
              { "path" => "heartbeats/.gitkeep", "type" => "blob" },
              { "path" => "batches/.gitkeep", "type" => "blob" }
            ]
          ),
          stderr: "",
          status: FakeStatus.new(true)
        )
      end

      raise "unexpected gh api #{args.inspect}"
    end
  end

  class EmptyLayoutGitHubStore < AgentCoord::GitHubStore
    def initialize
      super(backend: "shakacode/agent-coordination-state", ref: "state")
    end

    private

    def gh_api(*args)
      if args == ["repos/shakacode/agent-coordination-state/git/trees/state?recursive=1"]
        return AgentCoord::GhResult.new(stdout: JSON.generate("tree" => []), stderr: "", status: FakeStatus.new(true))
      end

      raise "unexpected gh api #{args.inspect}"
    end
  end

  class UnreadableTreeGitHubStore < AgentCoord::GitHubStore
    def initialize
      super(backend: "shakacode/agent-coordination-state", ref: "state")
    end

    private

    def gh_api(*args)
      if args == ["repos/shakacode/agent-coordination-state/git/trees/state?recursive=1"]
        return AgentCoord::GhResult.new(stdout: "", stderr: "rate limit", status: FakeStatus.new(false))
      end

      raise "unexpected gh api #{args.inspect}"
    end
  end

  private

  def write_heartbeat(agent_id, updated_at:, expires_at:, status: "in_progress")
    FileUtils.mkdir_p(File.join(@state_root, "heartbeats"))
    File.write(
      File.join(@state_root, "heartbeats", "#{agent_id}.json"),
      JSON.pretty_generate(
        "schema_version" => 1,
        "agent_id" => agent_id,
        "status" => status,
        "updated_at" => updated_at.iso8601,
        "expires_at" => expires_at.iso8601
      )
    )
  end

  def write_batch(batch_id, lanes:)
    FileUtils.mkdir_p(File.join(@state_root, "batches"))
    File.write(
      File.join(@state_root, "batches", "#{batch_id}.json"),
      JSON.pretty_generate(
        "schema_version" => 1,
        "batch_id" => batch_id,
        "lanes" => lanes,
        "updated_at" => Time.now.utc.iso8601
      )
    )
  end

  def write_claim(target, agent_id:, updated_at:, expires_at:)
    claim_dir = File.join(@state_root, "claims", "shakacode", "react_on_rails")
    FileUtils.mkdir_p(claim_dir)
    File.write(
      File.join(claim_dir, "#{target}.json"),
      JSON.pretty_generate(
        "schema_version" => 1,
        "repo" => "shakacode/react_on_rails",
        "target" => target,
        "agent_id" => agent_id,
        "batch_id" => "batch-1",
        "branch" => "jg-codex/#{agent_id}",
        "status" => "active",
        "claimed_at" => (updated_at - 30).iso8601,
        "updated_at" => updated_at.iso8601,
        "expires_at" => expires_at.iso8601
      )
    )
  end

  def run_agent_coord(*, state_root: @state_root)
    env = {}
    env["AGENT_COORD_STATE_ROOT"] = state_root if state_root
    run_command(env, "ruby", BIN, *)
  end

  def run_command(*args)
    env = args.first.is_a?(Hash) ? args.shift : {}
    stdout, stderr, status = Open3.capture3(COMMAND_ENV.merge(env), *args)
    CommandResult.new(stdout: stdout, stderr: stderr, status: status)
  end

  def with_agent_coord_without_source_state
    Dir.mktmpdir("agent-coord-source") do |root|
      bin_dir = File.join(root, "bin")
      FileUtils.mkdir_p(bin_dir)
      copied_bin = File.join(bin_dir, "agent-coord")
      FileUtils.cp(BIN, copied_bin)
      yield copied_bin
    end
  end

  def with_agent_coord_source_state
    Dir.mktmpdir("agent-coord-source-state") do |root|
      bin_dir = File.join(root, "bin")
      FileUtils.mkdir_p(bin_dir)
      copied_bin = File.join(bin_dir, "agent-coord")
      FileUtils.cp(BIN, copied_bin)
      %w[claims heartbeats batches].each { |prefix| FileUtils.mkdir_p(File.join(root, prefix)) }
      yield copied_bin, root
    end
  end

  def assert_demo_left_no_state(tmpdir, xdg_state_home)
    assert_empty Dir.children(tmpdir)
    refute_path_exists File.join(xdg_state_home, "agent-coordination")
    refute_path_exists File.join(tmpdir, "ambient-state")
    refute_path_exists File.join(tmpdir, "ambient-status-state")
  end

  def lane_metadata_args(overrides = {})
    {
      thread_handle: "p93s1v-docs-quokka",
      chat_handle: "codex-thread-123",
      host: "codex",
      pr_url: "https://github.com/shakacode/react_on_rails/pull/3973",
      dashboard_url: "https://coord.example.test/batches/batch-1/docs",
      operator: "justin",
      phase: "validating",
      instance_id: "instance-a",
      generation: 3
    }.merge(overrides).flat_map do |name, value|
      value.nil? ? [] : ["--#{name.to_s.tr('_', '-')}", value.to_s]
    end
  end

  def assert_lane_metadata(payload, overrides = {})
    {
      "thread_handle" => "p93s1v-docs-quokka",
      "chat_handle" => "codex-thread-123",
      "host" => "codex",
      "pr_url" => "https://github.com/shakacode/react_on_rails/pull/3973",
      "dashboard_url" => "https://coord.example.test/batches/batch-1/docs",
      "operator" => "justin",
      "phase" => "validating",
      "instance_id" => "instance-a",
      "generation" => 3
    }.merge(stringify_keys(overrides)).each do |key, value|
      if value.nil?
        refute(payload.key?(key), "expected #{key} to be absent")
      else
        assert_equal(value, payload.fetch(key))
      end
    end
  end

  def assert_absent_lane_metadata(payload, *extra_fields)
    expected_fields = %w[
      thread_handle chat_handle host pr_url dashboard_url operator phase generation instance_id
    ] + extra_fields

    expected_fields.each do |key|
      refute(payload.key?(key), "expected #{key} to be absent")
    end
  end

  def assert_handoff_release_claim(payload)
    {
      "status" => "released",
      "release_mode" => "handoff",
      "handoff_to" => "claude-code/conductor",
      "handoff_note" => "Continue from the failing docs spec.",
      "branch" => "jg-codex/handoff",
      "pr_url" => "https://github.com/shakacode/react_on_rails/pull/3975",
      "phase" => "validating"
    }.each { |key, value| assert_equal value, payload.fetch(key) }
  end

  def assert_handoff_release_event(event)
    {
      "type" => "handoff",
      "batch_id" => "batch-handoff",
      "agent_id" => "worker-a",
      "repo" => "shakacode/react_on_rails",
      "target" => "3975",
      "branch" => "jg-codex/handoff",
      "pr_url" => "https://github.com/shakacode/react_on_rails/pull/3975",
      "phase" => "validating",
      "status" => "released",
      "release_mode" => "handoff",
      "handoff_to" => "claude-code/conductor",
      "message" => "Continue from the failing docs spec."
    }.each { |key, value| assert_equal value, event.fetch(key) }
  end

  def assert_handoff_status_event(status_event, event_id)
    assert_equal event_id, status_event.fetch("event_id")
    assert_equal "handoff", status_event.fetch("type")
    assert_equal "claude-code/conductor", status_event.fetch("handoff_to")
    assert_equal "Continue from the failing docs spec.", status_event.fetch("message")
  end

  def refute_handoff_release_metadata(payload)
    %w[release_mode handoff_to handoff_note].each do |key|
      refute(payload.key?(key), "expected #{key} to be absent")
    end
  end

  def stringify_keys(hash)
    hash.transform_keys(&:to_s)
  end

  def with_fake_http_harness
    Dir.mktmpdir("agent-coord-http-harness") do |root|
      fake_bin = File.join(root, "bin")
      paths = fake_http_harness_paths(root)
      FileUtils.mkdir_p([fake_bin, paths.fetch(:tmpdir)])
      write_fake_http_harness_commands(fake_bin)

      yield fake_http_harness_env(fake_bin, paths), paths
    end
  end

  def fake_http_harness_paths(root)
    {
      tmpdir: File.join(root, "tmp"),
      npx_log: File.join(root, "npx.jsonl"),
      bundle_log: File.join(root, "bundle.log"),
      wrangler_pid: File.join(root, "wrangler.pid"),
      wrangler_stopped: File.join(root, "wrangler.stopped")
    }
  end

  def fake_http_harness_env(fake_bin, paths)
    {
      "BASH_ENV" => nil,
      "PATH" => [fake_bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
      "TMPDIR" => "#{paths.fetch(:tmpdir)}/",
      "FAKE_NPX_LOG" => paths.fetch(:npx_log),
      "FAKE_BUNDLE_LOG" => paths.fetch(:bundle_log),
      "FAKE_WRANGLER_PID" => paths.fetch(:wrangler_pid),
      "FAKE_WRANGLER_STOPPED" => paths.fetch(:wrangler_stopped)
    }
  end

  def assert_fake_http_harness_run(result, paths)
    assert_equal 0, result.status.exitstatus, "#{result.stdout}\n#{result.stderr}"
    assert_includes result.stdout, "INTEGRATION_OK"
    assert File.exist?(paths.fetch(:bundle_log)), fake_harness_diagnostics(result, paths)
    assert_equal "exec ruby test/http_backend_integration_test.rb", File.read(paths.fetch(:bundle_log))
    assert_fake_harness_events(paths)
  end

  def fake_harness_diagnostics(result, paths)
    events = File.exist?(paths.fetch(:npx_log)) ? File.read(paths.fetch(:npx_log)) : ""
    "#{result.stdout}\n#{result.stderr}\n#{events}"
  end

  def assert_fake_harness_events(paths)
    events = fake_harness_events(paths)
    execute = events.find { |event| event.key?("command") }
    assert execute, "no d1 execute command was recorded: #{events.inspect}"
    assert_match(/\b[0-9a-f]{64}\b/, execute.fetch("command"))
    refute_includes execute.fetch("command"), "integration-token-"

    migration = events.find { |event| event["argv"][0, 5] == %w[wrangler d1 migrations apply agent-coord] }
    assert migration, "no d1 migrations command was recorded: #{events.inspect}"

    dev = events.find { |event| event["argv"][0, 2] == %w[wrangler dev] }
    assert dev, "no wrangler dev command was recorded: #{events.inspect}"
    assert_includes dev.fetch("wrangler_output_log"), paths.fetch(:tmpdir)
    assert_fake_harness_persistence(paths, migration, execute, dev)
    assert_fake_harness_cleanup(paths)
  end

  def assert_fake_harness_persistence(paths, *events)
    persist_dirs = events.map { |event| persist_to_arg(event.fetch("argv")) }
    assert_equal 1, persist_dirs.uniq.size, "expected one Wrangler persistence dir: #{events.inspect}"
    assert_includes persist_dirs.first, paths.fetch(:tmpdir)
  end

  def persist_to_arg(argv)
    index = argv.index("--persist-to")
    index && argv.fetch(index + 1)
  end

  def assert_fake_harness_cleanup(paths)
    assert File.exist?(paths.fetch(:wrangler_stopped)), "fake wrangler did not receive TERM"
  end

  def fake_harness_events(paths)
    File.readlines(paths.fetch(:npx_log), chomp: true).map { |line| JSON.parse(line) }
  end

  def write_fake_http_harness_commands(fake_bin)
    File.write(File.join(fake_bin, "shasum"), FAKE_SHASUM)
    File.write(File.join(fake_bin, "bundle"), FAKE_BUNDLE)
    File.write(File.join(fake_bin, "npx"), FAKE_NPX)
    %w[shasum bundle npx].each { |name| FileUtils.chmod(0o755, File.join(fake_bin, name)) }
  end

  def write_fake_gh(fake_bin)
    File.write(
      File.join(fake_bin, "gh"),
      <<~'RUBY'
        #!/usr/bin/env ruby
        command = ARGV.join(" ")
        case command
        when "auth status", /\Arepo view /
          exit 0
        when %r{\Aapi repos/.+/git/trees/missing-ref\?recursive=1\z}
          warn "Not Found"
          exit 1
        else
          warn "unexpected gh command: #{command}"
          exit 1
        end
      RUBY
    )
    FileUtils.chmod(0o755, File.join(fake_bin, "gh"))
  end
end
