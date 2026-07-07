# frozen_string_literal: true

require "fileutils"
require "json"
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
  end

  def test_global_help_omits_doctor_only_deep_option
    result = run_agent_coord("--help", state_root: nil)
    doctor = run_agent_coord("doctor", "--help", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stdout, "--deep"
    assert_includes doctor.stdout, "--deep"
  end

  def test_status_help_omits_doctor_only_deep_option
    result = run_agent_coord("status", "--help", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stdout, "--deep"
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
    assert_equal "shakacode/agent-coordination-state", payload.fetch("default_backend")
    assert_equal "state", payload.fetch("default_ref")
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
    %w[claims batches].each do |prefix|
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
        "doctor"
      )

      assert_equal 2, result.status.exitstatus
      assert_includes result.stderr, "gh auth status failed"
      refute_includes result.stderr, "from "
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
  end

  def test_non_doctor_deep_guard_ignores_deep_as_option_value
    result = run_agent_coord("status", "--branch", "--deep", "--json")

    assert_equal 0, result.status.exitstatus, result.stderr
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

    status = run_command({ "AGENT_COORD_STATE_ROOT" => nil }, wrapper, "status")

    assert_equal 0, status.status.exitstatus, status.stderr
    assert_includes status.stdout, "worker-bootstrap-wrapper"
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
    assert_includes template, "ExecStart=/bin/bash -lc"
    assert_includes template, '--status "$$AGENT_COORD_STATUS"'
    assert_includes template, 'Environment="BRANCH=__BRANCH__"'
    refute_match(/ExecStart=.*__BRANCH__/, template)
  end

  def test_scheduler_templates_use_cli_without_state_branch_pinning
    launchd_heartbeat = File.read(LAUNCHD_HEARTBEAT_TEMPLATE)
    systemd_heartbeat = File.read(SYSTEMD_TEMPLATE)

    assert_includes launchd_heartbeat, "bin/agent-coord heartbeat"
    assert_includes systemd_heartbeat, "bin/agent-coord heartbeat"
    refute_includes launchd_heartbeat, "AGENT_COORD_REF=state"
    refute_includes systemd_heartbeat, "AGENT_COORD_REF=state"
  end

  def test_readme_documents_http_first_setup
    readme = File.read(File.join(ROOT, "README.md"))

    assert_includes readme, "The team/client runtime path is the HTTP backend"
    assert_includes readme, "AGENT_COORD_API_URL"
    assert_includes readme, "AGENT_COORD_API_TOKEN"
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
  end

  FakeStatus = Struct.new(:successful) do
    def success?
      successful
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
    stdout, stderr, status = Open3.capture3(env, *args)
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
