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
require "timeout"

class AgentCoordTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  THREAD_TIMEOUT = 5

  def self.wait_for_condition!(condition, mutex, label)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + THREAD_TIMEOUT
    until yield
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Timeout::Error, "timed out waiting for #{label}" unless remaining.positive?

      condition.wait(mutex, remaining)
    end
  end
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

  # In-process runners read the real process ENV, so keep them off the developer's
  # consumer env file, which would otherwise trip the split-brain guard.
  CONSUMER_ENV_KEYS = %w[AGENT_COORD_ENV_FILE AGENT_COORD_LOCAL XDG_CONFIG_HOME].freeze

  def setup
    @state_root = Dir.mktmpdir("agent-coord-test")
    @saved_consumer_env = CONSUMER_ENV_KEYS.to_h { |key| [key, ENV.fetch(key, nil)] }
    ENV.delete("AGENT_COORD_ENV_FILE")
    ENV.delete("AGENT_COORD_LOCAL")
    ENV["XDG_CONFIG_HOME"] = ISOLATED_CONFIG_HOME
  end

  def teardown
    @saved_consumer_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(@state_root)
  end

  def test_help_lists_commands
    result = run_agent_coord("--help", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "claim"
    assert_includes result.stdout, "release"
    assert_includes result.stdout, "heartbeat"
    assert_includes result.stdout, "gc"
    assert_includes result.stdout, "status"
    assert_includes result.stdout, "version"
    assert_includes result.stdout, "config"
    assert_includes result.stdout, "doctor"
    assert_includes result.stdout, "bootstrap"
    assert_includes result.stdout, "demo"
  end

  def test_gc_requires_an_explicit_mode
    result = run_agent_coord("gc")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "gc requires exactly one of --dry-run or --execute"
  end

  def test_gc_prefix_limits_hot_scans_but_still_deletes_expired_archive
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    old = (now - (8 * 86_400)).iso8601
    write_state_record(
      "claims/shakacode/example/selected.json",
      "schema_version" => 1, "repo" => "shakacode/example", "target" => "selected",
      "agent_id" => "worker", "status" => "released", "updated_at" => old
    )
    write_state_record(
      "batches/not-selected.json",
      "schema_version" => 1, "batch_id" => "not-selected", "status" => "completed",
      "completed_at" => old, "updated_at" => old, "lanes" => []
    )
    write_state_record(
      "archive/heartbeats/expired.json",
      "schema_version" => 1, "record_family" => "archived_record",
      "source_path" => "heartbeats/expired.json", "reason" => "dead_heartbeat", "synthetic" => false,
      "archived_at" => old, "delete_after" => (now - 1).iso8601, "data" => { "schema_version" => 1 }
    )
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(
      :gc, state_root: @state_root, dry_run: true, execute: false, json: true, prefixes: ["claims"]
    )
    actions = JSON.parse(stdout.string).fetch("actions")
    assert_equal %w[archive delete], actions.map { |action| action["action"] }.sort
    refute(actions.any? { |action| action["source_path"] == "batches/not-selected.json" })
  end

  def test_gc_prefix_rejects_empty_and_unknown_values
    ["", "archive", "Claims"].each do |value|
      result = run_agent_coord("gc", "--dry-run", "--prefix", value)
      assert_equal 1, result.status.exitstatus
      assert_includes result.stderr, "--prefix must be one of"
    end
  end

  def test_gc_classifies_canonical_terminal_heartbeats_and_keeps_legacy_synonyms_on_dead_path
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    old = (now - (8 * 86_400)).iso8601
    old_expiry = (now - (8 * 86_400) + 900).iso8601
    write_state_record(
      "heartbeats/canonical-terminal.json",
      "schema_version" => 1, "agent_id" => "canonical-terminal", "status" => "merged",
      "updated_at" => old, "expires_at" => old_expiry
    )
    write_state_record(
      "heartbeats/legacy-synonym.json",
      "schema_version" => 1, "agent_id" => "legacy-synonym", "status" => "completed",
      "updated_at" => old, "expires_at" => old_expiry
    )
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))

    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)

    reasons = JSON.parse(stdout.string).fetch("actions").to_h do |action|
      [action.fetch("source_path"), action.fetch("reason")]
    end
    assert_equal "terminal_heartbeat", reasons.fetch("heartbeats/canonical-terminal.json")
    assert_equal "dead_heartbeat", reasons.fetch("heartbeats/legacy-synonym.json")
  end

  def test_gc_reuses_identical_mirrors_defers_unexpired_conflicts_and_replaces_expired_conflicts
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    old = (now - (8 * 86_400)).iso8601
    claim_path = "claims/shakacode/example/replacement.json"
    claim_data = { "schema_version" => 1, "repo" => "shakacode/example", "target" => "replacement",
                   "agent_id" => "worker", "status" => "released", "updated_at" => old }
    archive_path = "archive/#{claim_path}"
    write_state_record(claim_path, claim_data)
    write_state_record(
      archive_path, archived_record_for(claim_path, claim_data.merge("agent_id" => "old"), now - 1)
    )
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)
    action = JSON.parse(stdout.string).fetch("actions").find { |row| row["source_path"] == claim_path }
    assert_equal "replace_archive", action.fetch("action")
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    refute_path_exists File.join(@state_root, claim_path)
    assert_equal claim_data, JSON.parse(File.read(File.join(@state_root, archive_path))).fetch("data")

    deferred_path = "claims/shakacode/example/deferred.json"
    deferred_data = claim_data.merge("target" => "deferred")
    write_state_record(deferred_path, deferred_data)
    write_state_record(
      "archive/#{deferred_path}",
      archived_record_for(deferred_path, deferred_data.merge("agent_id" => "other"), now + 86_400)
    )
    deferred_stdout = StringIO.new
    deferred_runner = AgentCoord::Runner.new([], stdout: deferred_stdout, clock: FixedClock.new(now))
    assert_equal 0, deferred_runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)
    deferred_actions = JSON.parse(deferred_stdout.string).fetch("actions")
    refute(deferred_actions.any? { |row| row["source_path"] == deferred_path })
    assert_path_exists File.join(@state_root, deferred_path)
  end

  def test_gc_reuses_identical_claim_and_heartbeat_mirrors
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    old = (now - (8 * 86_400)).iso8601
    records = {
      "claims/shakacode/example/reuse-claim.json" => {
        "schema_version" => 1, "repo" => "shakacode/example", "target" => "reuse-claim",
        "agent_id" => "reuse", "status" => "released", "updated_at" => old
      },
      "heartbeats/reuse-heartbeat.json" => {
        "schema_version" => 1, "agent_id" => "reuse-heartbeat", "status" => "in_progress",
        "updated_at" => old, "expires_at" => (Time.iso8601(old) + 900).iso8601
      }
    }
    records.each do |path, data|
      write_state_record(path, data)
      write_state_record("archive/#{path}", archived_record_for(path, data, now + 86_400))
    end
    runner = AgentCoord::Runner.new([], stdout: StringIO.new, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    records.each_key do |path|
      refute_path_exists File.join(@state_root, path)
      assert_path_exists File.join(@state_root, "archive", path)
    end
  end

  def test_gc_expired_replacement_conflict_leaves_hot_source_safe
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    source_path = "claims/shakacode/example/replacement-conflict.json"
    data = { "schema_version" => 1, "repo" => "shakacode/example", "target" => "replacement-conflict",
             "agent_id" => "worker", "status" => "released", "updated_at" => (now - (8 * 86_400)).iso8601 }
    archive_path = "archive/#{source_path}"
    write_state_record(source_path, data)
    write_state_record(archive_path, archived_record_for(source_path, data.merge("agent_id" => "old"), now - 1))
    store = AgentCoord::LocalStore.new(@state_root)
    runner = AgentCoord::Runner.new([], stdout: StringIO.new, clock: FixedClock.new(now))
    candidate = runner.send(:gc_archive_candidates, store, now, 7, 1, ["claims"]).fetch(0)
    mutated = JSON.parse(File.read(File.join(@state_root, archive_path))).merge("reason" => "concurrent")
    File.write(File.join(@state_root, archive_path), JSON.pretty_generate(mutated))

    assert_raises(AgentCoord::OperationalError) do
      runner.send(:gc_replace_archive_record, store, candidate, now, 30)
    end
    assert_path_exists File.join(@state_root, source_path)
  end

  def test_gc_dry_run_uses_terminal_semantics_and_default_7_day_hot_policy
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    write_state_record(
      "claims/shakacode/example/old.json",
      "schema_version" => 1,
      "repo" => "shakacode/example",
      "target" => "old",
      "agent_id" => "worker-old",
      "status" => "released",
      "terminal" => "done",
      "updated_at" => (now - (8 * 86_400)).iso8601
    )
    write_state_record(
      "claims/shakacode/example/hot.json",
      "schema_version" => 1,
      "repo" => "shakacode/example",
      "target" => "hot",
      "agent_id" => "worker-hot",
      "status" => "released",
      "terminal" => "done",
      "updated_at" => (now - (6 * 86_400)).iso8601
    )
    write_state_record(
      "claims/shakacode/example/active.json",
      "schema_version" => 1,
      "repo" => "shakacode/example",
      "target" => "active",
      "agent_id" => "worker-active",
      "status" => "active",
      "updated_at" => (now - (30 * 86_400)).iso8601,
      "expires_at" => (now - (29 * 86_400)).iso8601
    )

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    result = runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)

    assert_equal 0, result
    payload = JSON.parse(stdout.string)
    assert_equal "dry-run", payload.fetch("mode")
    assert_equal 7, payload.fetch("policy").fetch("hot_days")
    assert_equal 30, payload.fetch("policy").fetch("archive_days")
    assert_equal(["claims/shakacode/example/old.json"], payload.fetch("actions").map { |row| row.fetch("source_path") })
    assert_equal "archive", payload.fetch("actions").first.fetch("action")
    assert_empty Dir.glob(File.join(@state_root, "archive", "**", "*.json"))
  end

  def test_gc_applies_synthetic_window_only_after_family_specific_eligibility
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    synthetic_family_policy_records(now).each { |path, data| write_state_record(path, data) }

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)

    sources = JSON.parse(stdout.string).fetch("actions").map { |action| action["source_path"] }.compact.sort
    assert_equal(
      %w[batches/completed-synthetic.json claims/shakacode/example/released.json heartbeats/dead-synthetic.json],
      sources
    )
    execute_runner = AgentCoord::Runner.new([], stdout: StringIO.new, clock: FixedClock.new(now))
    assert_equal 0, execute_runner.send(
      :gc, state_root: @state_root, dry_run: false, execute: true, json: true
    )
    assert_path_exists File.join(@state_root, "claims/shakacode/example/scripted-active.json")
    assert_path_exists File.join(@state_root, "heartbeats/scripted-worker.json")
    assert_path_exists File.join(@state_root, "batches/incomplete-synthetic.json")
    sources.each do |source|
      refute_path_exists File.join(@state_root, source)
      assert_path_exists File.join(@state_root, "archive", source)
    end
  end

  def test_gc_execute_archives_terminal_record_with_a_30_day_delete_deadline
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    source_path = "claims/shakacode/example/old.json"
    write_state_record(
      source_path,
      "schema_version" => 1,
      "repo" => "shakacode/example",
      "target" => "old",
      "agent_id" => "worker-old",
      "status" => "released",
      "terminal" => "done",
      "updated_at" => (now - (8 * 86_400)).iso8601
    )

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    result = runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)

    assert_equal 0, result
    refute_path_exists File.join(@state_root, source_path)
    archive_path = File.join(@state_root, "archive", source_path)
    assert_path_exists archive_path
    archived = JSON.parse(File.read(archive_path))
    assert_equal 1, archived.fetch("schema_version")
    assert_equal "archived_record", archived.fetch("record_family")
    assert_equal source_path, archived.fetch("source_path")
    assert_equal now.iso8601, archived.fetch("archived_at")
    assert_equal (now + (30 * 86_400)).iso8601, archived.fetch("delete_after")
    assert_equal "old", archived.fetch("data").fetch("target")
  end

  def test_gc_execute_deletes_archive_after_30_days
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    archive_path = "archive/claims/shakacode/example/old.json"
    write_state_record(
      archive_path,
      "schema_version" => 1,
      "record_family" => "archived_record",
      "source_path" => "claims/shakacode/example/old.json",
      "reason" => "terminal_claim",
      "synthetic" => false,
      "archived_at" => (now - (31 * 86_400)).iso8601,
      "delete_after" => (now - 86_400).iso8601,
      "data" => { "schema_version" => 1, "status" => "released" }
    )

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    result = runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)

    assert_equal 0, result
    refute_path_exists File.join(@state_root, archive_path)
    actions = JSON.parse(stdout.string).fetch("actions")
    assert_equal 1, actions.length
    action = actions.fetch(0)
    assert_equal "delete", action.fetch("action")
    assert_equal archive_path, action.fetch("source_path")
    assert_equal "archive_expired", action.fetch("reason")
  end

  def test_gc_protects_reused_archive_and_compaction_destinations_until_a_later_run
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    sources, destinations = write_expired_reuse_candidates(now)

    dry_stdout = StringIO.new
    dry_runner = AgentCoord::Runner.new([], stdout: dry_stdout, clock: FixedClock.new(now))
    assert_equal 0, dry_runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)
    dry_actions = JSON.parse(dry_stdout.string).fetch("actions")
    assert_equal %w[archive compact], dry_actions.map { |action| action.fetch("action") }.sort
    refute(dry_actions.any? { |action| destinations.include?(action["source_path"]) })

    execute_runner = AgentCoord::Runner.new([], stdout: StringIO.new, clock: FixedClock.new(now))
    assert_equal 0, execute_runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    sources.each { |path| refute_path_exists File.join(@state_root, path) }
    destinations.each { |path| assert_path_exists File.join(@state_root, path) }

    later_stdout = StringIO.new
    later_runner = AgentCoord::Runner.new([], stdout: later_stdout, clock: FixedClock.new(now + 1))
    assert_equal 0, later_runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    later_actions = JSON.parse(later_stdout.string).fetch("actions")
    assert_equal(%w[delete delete], later_actions.map { |action| action["action"] })
    destinations.each { |path| refute_path_exists File.join(@state_root, path) }
  end

  def test_gc_rejects_an_oversized_archive_envelope_before_writing_any_candidate
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    %w[small oversized].each do |target|
      write_state_record(
        "claims/shakacode/example/#{target}.json",
        "schema_version" => 1, "repo" => "shakacode/example", "target" => target,
        "agent_id" => "worker-#{target}", "status" => "released", "terminal" => "done",
        "updated_at" => (now - (8 * 86_400)).iso8601,
        "padding" => (target == "oversized" ? "x" * AgentCoord::MAX_ARCHIVE_STATE_BYTES : "")
      )
    end
    runner = AgentCoord::Runner.new([], stdout: StringIO.new, clock: FixedClock.new(now))

    errors = [[true, false], [false, true]].map do |dry_run, execute|
      assert_raises(AgentCoord::OperationalError) do
        runner.send(:gc, state_root: @state_root, dry_run: dry_run, execute: execute, json: true)
      end
    end

    errors.each { |error| assert_includes error.message, "gc archive envelope exceeds 1048576 bytes" }
    assert_path_exists File.join(@state_root, "claims/shakacode/example/small.json")
    assert_path_exists File.join(@state_root, "claims/shakacode/example/oversized.json")
    refute_path_exists File.join(@state_root, "archive")
  end

  def test_gc_fail_closed_timestamp_errors_identify_claim_and_event_paths
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    claim_path = "claims/shakacode/example/malformed-time.json"
    write_state_record(
      claim_path,
      "schema_version" => 1, "repo" => "shakacode/example", "target" => "malformed-time",
      "agent_id" => "worker", "status" => "released"
    )
    runner = AgentCoord::Runner.new([], stdout: StringIO.new, clock: FixedClock.new(now))
    claim_error = assert_raises(AgentCoord::OperationalError) do
      runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)
    end
    assert_includes claim_error.message, claim_path
    FileUtils.rm(File.join(@state_root, claim_path))

    event_path = "events/malformed-time/no-time.json"
    write_state_record(
      event_path,
      "schema_version" => 1, "event_id" => "no-time", "batch_id" => "malformed-time",
      "type" => "phase", "lane" => "simulation", "synthetic" => true
    )
    event_error = assert_raises(AgentCoord::OperationalError) do
      runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)
    end
    assert_includes event_error.message, event_path
  end

  def test_gc_typed_claim_timestamps_exit_operational_with_path_and_no_backtrace
    { "integer" => 12_345, "object" => { "unexpected" => "timestamp" } }.each do |name, value|
      claim_path = "claims/shakacode/example/typed-#{name}.json"
      write_state_record(
        claim_path,
        "schema_version" => 1, "repo" => "shakacode/example", "target" => "typed-#{name}",
        "agent_id" => "worker", "status" => "released", "updated_at" => value
      )

      result = run_agent_coord("gc", "--dry-run", "--json")

      assert_equal 2, result.status.exitstatus
      assert_includes result.stderr, "gc record has invalid retention timestamp at #{claim_path}"
      refute_includes result.stderr, "bin/agent-coord:"
      FileUtils.rm(File.join(@state_root, claim_path))
    end
  end

  def test_gc_text_renders_delete_and_compaction_actions_without_assuming_archive_shape
    payload = {
      "mode" => "dry-run",
      "policy" => { "hot_days" => 7, "archive_days" => 30, "synthetic_hot_days" => 1 },
      "actions" => [
        {
          "action" => "compact", "source_paths" => %w[events/b/e1.json events/b/e2.json],
          "archive_path" => "archive/events/b/compact-a.json", "reason" => "terminal_target_events"
        },
        {
          "action" => "delete", "source_path" => "archive/claims/o/r/1.json", "reason" => "archive_expired"
        }
      ]
    }
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout)

    runner.send(:render_gc_text, payload)

    assert_includes stdout.string, "synthetic_hot=1d"
    assert_includes stdout.string, "compact events/b/e1.json,events/b/e2.json -> archive/events/b/compact-a.json"
    assert_includes stdout.string, "delete archive/claims/o/r/1.json (archive_expired)"
  end

  def test_synthetic_marker_is_written_and_preserved_across_claim_and_heartbeat_updates
    claim = run_agent_coord(
      "claim", "--agent-id", "sim-worker", "--repo", "shakacode/example", "--target", "smoke-1",
      "--synthetic", "--synthetic-kind", "simulation"
    )
    heartbeat = run_agent_coord(
      "heartbeat", "--agent-id", "sim-worker", "--repo", "shakacode/example", "--target", "smoke-1",
      "--synthetic", "--synthetic-kind", "simulation"
    )
    refresh = run_agent_coord("heartbeat", "--agent-id", "sim-worker", "--status", "validating")

    assert_equal 0, claim.status.exitstatus, claim.stderr
    assert_equal 0, heartbeat.status.exitstatus, heartbeat.stderr
    assert_equal 0, refresh.status.exitstatus, refresh.stderr
    claim_payload = JSON.parse(File.read(File.join(@state_root, "claims", "shakacode", "example", "smoke-1.json")))
    heartbeat_payload = JSON.parse(File.read(File.join(@state_root, "heartbeats", "sim-worker.json")))
    [claim_payload, heartbeat_payload].each do |payload|
      assert_equal true, payload.fetch("synthetic")
      assert_equal "simulation", payload.fetch("synthetic_kind")
    end
  end

  def test_terminal_release_preserves_synthetic_marker_on_canonical_lane_closed_event
    write_batch(
      "batch-synthetic-terminal",
      lanes: [{ "name" => "simulation", "owner" => "sim-worker", "targets" => ["synthetic-terminal"] }]
    )
    claim = run_agent_coord(
      "claim", "--agent-id", "sim-worker", "--repo", "shakacode/example", "--target", "synthetic-terminal",
      "--batch-id", "batch-synthetic-terminal", "--synthetic", "--synthetic-kind", "simulation"
    )
    release = run_agent_coord(
      "release", "--agent-id", "sim-worker", "--repo", "shakacode/example", "--target", "synthetic-terminal",
      "--terminal", "done"
    )

    assert_equal 0, claim.status.exitstatus, claim.stderr
    assert_equal 0, release.status.exitstatus, release.stderr
    event = event_of_type("batch-synthetic-terminal", "lane_closed")
    assert_equal "lane_closed", event.fetch("type")
    assert_equal true, event.fetch("synthetic")
    assert_equal "simulation", event.fetch("synthetic_kind")
  end

  def test_gc_compacts_events_per_target_after_terminal_closeout
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    at = (now - (8 * 86_400)).iso8601
    { "claimed" => ["claimed", 0], "claimed-renewal" => ["claimed", 1],
      "validating" => ["validating", 2] }.each do |event_id, (phase, offset)|
      write_state_record(
        "events/batch-1/#{event_id}.json",
        "schema_version" => 1,
        "event_id" => event_id,
        "batch_id" => "batch-1",
        "type" => "phase",
        "repo" => "shakacode/example",
        "target" => "42",
        "phase" => phase,
        "at" => (Time.iso8601(at) + offset).iso8601
      )
    end
    write_state_record(
      "events/batch-1/lane_closed-deadbeef.json",
      valid_gc_lane_closed(
        event_id: "lane_closed-deadbeef", batch_id: "batch-1", target: "42",
        at: (Time.iso8601(at) + 3).iso8601
      )
    )

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    result = runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)

    assert_equal 0, result
    action = JSON.parse(stdout.string).fetch("actions").find { |row| row["action"] == "compact" }
    refute_nil action
    assert_equal 4, action.fetch("source_paths").length
    action.fetch("source_paths").each { |path| refute_path_exists File.join(@state_root, path) }
    compacted = JSON.parse(File.read(File.join(@state_root, action.fetch("archive_path"))))
    assert_equal "compacted_events", compacted.fetch("record_family")
    assert_equal(%w[claimed validating lane_closed-deadbeef], compacted.fetch("records").map do |row|
      row.fetch("event_id")
    end)
    refute_includes compacted.fetch("records").map { |row| row.fetch("event_id") }, "claimed-renewal"
  end

  def test_gc_terminal_compaction_is_scoped_to_one_lane
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    old = (now - (8 * 86_400)).iso8601
    write_state_record(
      "events/lane-scoped/lane-a-phase.json",
      "schema_version" => 1, "event_id" => "lane-a-phase", "batch_id" => "lane-scoped",
      "type" => "phase", "lane" => "lane-a", "repo" => "shakacode/example", "target" => "shared",
      "phase" => "qa", "at" => old
    )
    write_state_record(
      "events/lane-scoped/lane-a-closed.json",
      valid_gc_lane_closed(
        event_id: "lane-a-closed", batch_id: "lane-scoped", target: "shared", at: old,
        extra: { "lane" => "lane-a" }
      )
    )
    write_state_record(
      "events/lane-scoped/lane-b-phase.json",
      "schema_version" => 1, "event_id" => "lane-b-phase", "batch_id" => "lane-scoped",
      "type" => "phase", "lane" => "lane-b", "repo" => "shakacode/example", "target" => "shared",
      "phase" => "implementation", "at" => old
    )

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)

    action = JSON.parse(stdout.string).fetch("actions").find { |row| row["action"] == "compact" }
    assert_equal %w[events/lane-scoped/lane-a-closed.json events/lane-scoped/lane-a-phase.json],
                 action.fetch("source_paths")
    assert_path_exists File.join(@state_root, "events/lane-scoped/lane-b-phase.json")
  end

  def test_gc_compaction_retains_interior_terminal_before_later_nonterminal_event
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    old = now - (8 * 86_400)
    records = {
      "first" => {
        "schema_version" => 1, "event_id" => "first", "batch_id" => "interior-terminal",
        "type" => "phase", "lane" => "code", "repo" => "shakacode/example", "target" => "interior",
        "phase" => "implementation", "at" => old.iso8601
      },
      "lane_closed" => valid_gc_lane_closed(
        event_id: "lane_closed", batch_id: "interior-terminal", target: "interior", at: (old + 1).iso8601,
        extra: { "lane" => "code", "evidence_url" => "https://example.test/evidence" }
      ),
      "later" => {
        "schema_version" => 1, "event_id" => "later", "batch_id" => "interior-terminal",
        "type" => "milestone", "lane" => "code", "repo" => "shakacode/example", "target" => "interior",
        "message" => "late delivery", "at" => (old + 2).iso8601
      }
    }
    records.each { |event_id, data| write_state_record("events/interior-terminal/#{event_id}.json", data) }

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)

    action = JSON.parse(stdout.string).fetch("actions").find { |row| row["action"] == "compact" }
    compacted = JSON.parse(File.read(File.join(@state_root, action.fetch("archive_path"))))
    assert_equal(%w[first lane_closed later], compacted.fetch("records").map { |record| record["event_id"] })
    terminal = compacted.fetch("records").find { |record| record["type"] == "lane_closed" }
    assert_equal "https://example.test/evidence", terminal.fetch("evidence_url")
    action.fetch("source_paths").each { |path| refute_path_exists File.join(@state_root, path) }
  end

  def test_gc_joins_lane_less_handoff_to_the_only_terminal_lane
    write_batch(
      "batch-handoff-gc",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["handoff-gc"] }]
    )
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/example", "--target", "handoff-gc",
      "--batch-id", "batch-handoff-gc"
    )
    handoff = run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/example", "--target", "handoff-gc",
      "--handoff-to", "worker-a", "--handoff-note", "resume"
    )
    reclaim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/example", "--target", "handoff-gc",
      "--batch-id", "batch-handoff-gc"
    )
    close = run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/example", "--target", "handoff-gc",
      "--terminal", "done"
    )
    [claim, handoff, reclaim, close].each { |result| assert_equal 0, result.status.exitstatus, result.stderr }
    event_paths = Dir.glob(File.join(@state_root, "events/batch-handoff-gc/*.json"))
    events = event_paths.map { |path| JSON.parse(File.read(path)) }
    assert_equal(1, events.count { |event| event["type"] == "claim.released" && !event.key?("lane") })
    assert_equal(1, events.count { |event| event["type"] == "lane_closed" && event["lane"] == "code" })
    old = (Time.utc(2026, 7, 12, 12, 0, 0) - (8 * 86_400)).iso8601
    event_paths.each do |path|
      event = JSON.parse(File.read(path)).merge("at" => old)
      File.write(path, JSON.pretty_generate(event))
    end

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(Time.utc(2026, 7, 12, 12, 0, 0)))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)
    action = JSON.parse(stdout.string).fetch("actions").find { |row| row["action"] == "compact" }
    assert_equal event_paths.map { |path| path.delete_prefix("#{@state_root}/") }.sort, action.fetch("source_paths")
  end

  def test_gc_keeps_lane_less_history_separate_when_terminal_lane_is_ambiguous
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    old = (now - (8 * 86_400)).iso8601
    %w[lane-a lane-b].each do |lane|
      write_state_record(
        "events/ambiguous-lanes/#{lane}-closed.json",
        valid_gc_lane_closed(
          event_id: "#{lane}-closed", batch_id: "ambiguous-lanes", target: "shared", at: old,
          extra: { "lane" => lane }
        )
      )
    end
    handoff_path = "events/ambiguous-lanes/lane-less-handoff.json"
    write_state_record(
      handoff_path,
      "schema_version" => 1, "event_id" => "lane-less-handoff", "batch_id" => "ambiguous-lanes",
      "type" => "handoff", "repo" => "shakacode/example", "target" => "shared", "at" => old
    )

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    actions = JSON.parse(stdout.string).fetch("actions").select { |row| row["action"] == "compact" }
    assert_equal 2, actions.length
    refute(actions.any? { |action| action.fetch("source_paths").include?(handoff_path) })
    assert_path_exists File.join(@state_root, handoff_path)
  end

  def test_gc_compacts_only_events_whose_individual_hot_window_has_elapsed
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    old_at = (now - (8 * 86_400)).iso8601
    fresh_at = (now - 86_400).iso8601
    write_state_record(
      "events/batch-mixed/lane_closed-old.json",
      valid_gc_lane_closed(event_id: "lane_closed-old", batch_id: "batch-mixed", target: "mixed", at: old_at)
    )
    write_state_record(
      "events/batch-mixed/fresh.json",
      "schema_version" => 1, "event_id" => "fresh", "batch_id" => "batch-mixed",
      "type" => "phase", "repo" => "shakacode/example", "target" => "mixed",
      "phase" => "qa", "at" => fresh_at
    )

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)

    assert_empty JSON.parse(stdout.string).fetch("actions")
    assert_path_exists File.join(@state_root, "events/batch-mixed/lane_closed-old.json")
    assert_path_exists File.join(@state_root, "events/batch-mixed/fresh.json")

    later_stdout = StringIO.new
    later_runner = AgentCoord::Runner.new([], stdout: later_stdout, clock: FixedClock.new(now + (7 * 86_400)))
    assert_equal 0, later_runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    action = JSON.parse(later_stdout.string).fetch("actions").find { |row| row["action"] == "compact" }
    assert_equal 2, action.fetch("source_paths").length
    action.fetch("source_paths").each { |path| refute_path_exists File.join(@state_root, path) }
  end

  def test_gc_requires_a_valid_v2_lane_closed_terminal_marker_before_compacting_events
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    at = (now - (8 * 86_400)).iso8601
    valid = valid_gc_lane_closed(event_id: "lane_closed-invalid", batch_id: "batch-invalid", target: "invalid", at: at)
    invalid_markers = [
      valid.merge("schema_version" => 1),
      valid.merge("terminal" => "unknown"),
      valid.merge("type" => "phase"),
      valid.except("workspace"),
      valid.except("closed_by"),
      valid.merge("closed_by" => { "agent_id" => "gc-worker", "machine" => "" }),
      valid.merge("closed_by" => { "agent_id" => "gc-worker", "machine" => "test", "extra" => "no" }),
      valid.merge("event_id" => ""),
      valid.merge("target" => ""),
      valid.merge("repo" => "not-a-repo"),
      valid.merge("at" => "not-a-time"),
      valid.merge("pr_url" => "file:///tmp/not-http")
    ]
    invalid_markers.each_with_index do |marker, index|
      write_state_record(
        "events/batch-invalid-#{index}/lane_closed-invalid.json",
        marker.merge("batch_id" => "batch-invalid-#{index}")
      )
    end

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)
    assert_empty JSON.parse(stdout.string).fetch("actions")
  end

  def test_gc_compaction_retry_accepts_consumed_renewal_paths_without_positional_records
    at = "2026-07-01T00:00:00Z"
    entries = [
      AgentCoord::StoredJson.new(path: "events/b/first.json", data: { "event_id" => "first", "at" => at }),
      AgentCoord::StoredJson.new(path: "events/b/renewal.json", data: { "event_id" => "renewal", "at" => at }),
      AgentCoord::StoredJson.new(path: "events/b/last.json", data: { "event_id" => "last", "at" => at })
    ]
    retained = [entries.fetch(0), entries.fetch(2)]
    existing = {
      "record_family" => "compacted_events",
      "source_paths" => entries.map(&:path),
      "records" => retained.map(&:data)
    }
    runner = AgentCoord::Runner.new([])

    assert runner.send(:gc_compaction_contains?, existing, entries, retained)
    refute runner.send(:gc_compaction_contains?, existing, entries, [entries.fetch(1)])
  end

  def test_gc_uses_one_day_hot_window_for_synthetic_terminal_events
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    at = (now - (2 * 86_400)).iso8601
    write_state_record(
      "events/synthetic/lane_closed-synthetic.json",
      valid_gc_lane_closed(
        event_id: "lane_closed-synthetic", batch_id: "synthetic", target: "synthetic", at: at,
        extra: { "synthetic" => true }
      )
    )

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    result = runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)

    assert_equal 0, result
    action = JSON.parse(stdout.string).fetch("actions").find { |row| row["action"] == "compact" }
    refute_nil action
    assert_equal ["events/synthetic/lane_closed-synthetic.json"], action.fetch("source_paths")
  end

  def test_gc_compacts_aged_synthetic_orphan_events_without_terminal_marker
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    old = now - (2 * 86_400)
    { "first" => ["claimed", 0], "renewal" => ["claimed", 1],
      "transition" => ["qa", 2], "last" => ["qa", 3] }.each do |event_id, (phase, offset)|
      write_state_record(
        "events/orphan-synthetic/#{event_id}.json",
        "schema_version" => 1, "event_id" => event_id, "batch_id" => "orphan-synthetic",
        "type" => "phase", "repo" => "shakacode/example", "target" => "orphan",
        "phase" => phase, "synthetic" => true, "at" => (old + offset).iso8601
      )
    end
    write_state_record(
      "events/orphan-normal/old.json",
      "schema_version" => 1, "event_id" => "old", "batch_id" => "orphan-normal",
      "type" => "phase", "repo" => "shakacode/example", "target" => "normal-orphan",
      "phase" => "claimed", "at" => (now - (30 * 86_400)).iso8601
    )

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)

    action = JSON.parse(stdout.string).fetch("actions").find { |row| row["action"] == "compact" }
    assert_equal "synthetic_orphan_events", action.fetch("reason")
    assert_equal 4, action.fetch("source_paths").length
    envelope = JSON.parse(File.read(File.join(@state_root, action.fetch("archive_path"))))
    assert_equal(%w[first transition last], envelope.fetch("records").map { |record| record.fetch("event_id") })
    assert_path_exists File.join(@state_root, "events/orphan-normal/old.json")
  end

  def test_gc_defers_synthetic_orphan_group_until_every_event_ages
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    { "old" => now - (2 * 86_400), "fresh" => now - 3600 }.each do |event_id, at|
      write_state_record(
        "events/orphan-mixed-age/#{event_id}.json",
        "schema_version" => 1, "event_id" => event_id, "batch_id" => "orphan-mixed-age",
        "type" => "phase", "repo" => "shakacode/example", "target" => "orphan-mixed-age",
        "phase" => event_id, "synthetic" => true, "at" => at.iso8601
      )
    end
    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)
    assert_empty JSON.parse(stdout.string).fetch("actions")

    later_stdout = StringIO.new
    later = AgentCoord::Runner.new([], stdout: later_stdout, clock: FixedClock.new(now + (2 * 86_400)))
    assert_equal 0, later.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)
    assert_equal 1, JSON.parse(later_stdout.string).fetch("actions").length
  end

  def test_gc_compacts_metadata_less_synthetic_orphans_per_lane_and_available_provenance
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    old = (now - (2 * 86_400)).iso8601
    synthetic_events = {
      "legacy" => {},
      "lane-a" => { "lane" => "lane-a" },
      "repo-only" => { "lane" => "repo-only", "repo" => "shakacode/example" },
      "target-only" => { "lane" => "target-only", "target" => "known-target" }
    }
    synthetic_events.each do |event_id, provenance|
      write_state_record(
        "events/orphan-meta/#{event_id}.json",
        { "schema_version" => 1, "event_id" => event_id, "batch_id" => "orphan-meta",
          "type" => "phase", "phase" => "simulation", "synthetic" => true, "at" => old }.merge(provenance)
      )
    end
    write_state_record(
      "events/orphan-meta/fresh.json",
      "schema_version" => 1, "event_id" => "fresh", "batch_id" => "orphan-meta", "type" => "phase",
      "lane" => "fresh", "synthetic" => true, "at" => (now - 3600).iso8601
    )
    write_state_record(
      "events/orphan-meta/normal.json",
      "schema_version" => 1, "event_id" => "normal", "batch_id" => "orphan-meta", "type" => "phase",
      "lane" => "normal", "at" => (now - (30 * 86_400)).iso8601
    )

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)

    actions = JSON.parse(stdout.string).fetch("actions").select { |row| row["action"] == "compact" }
    assert_equal 4, actions.length
    assert(actions.all? { |action| action["reason"] == "synthetic_orphan_events" })
    archive_pattern = %r{\Aarchive/events/orphan-meta/compact-[0-9a-f]{16}-[0-9a-f]{16}\.json\z}
    assert(actions.all? { |action| action["archive_path"].match?(archive_pattern) })
    source_paths = actions.flat_map { |action| action.fetch("source_paths") }
    source_names = source_paths.map { |path| File.basename(path, ".json") }.sort
    assert_equal synthetic_events.keys.sort, source_names
    assert_path_exists File.join(@state_root, "events/orphan-meta/fresh.json")
    assert_path_exists File.join(@state_root, "events/orphan-meta/normal.json")
  end

  def test_gc_creates_an_immutable_generation_when_terminal_history_reappears
    now = Time.utc(2026, 7, 20, 12, 0, 0)
    old_at = (now - (8 * 86_400)).iso8601
    write_state_record(
      "events/batch-replay/phase-first.json",
      "schema_version" => 1, "event_id" => "phase-first", "batch_id" => "batch-replay",
      "type" => "phase", "repo" => "shakacode/example", "target" => "replay", "phase" => "claimed", "at" => old_at
    )
    write_state_record(
      "events/batch-replay/lane_closed-first.json",
      valid_gc_lane_closed(event_id: "lane_closed-first", batch_id: "batch-replay", target: "replay", at: old_at)
    )
    runner = AgentCoord::Runner.new([], stdout: StringIO.new, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    first_path = Dir.glob(File.join(@state_root, "archive/events/batch-replay/*.json")).fetch(0)
    first_bytes = File.binread(first_path)

    write_state_record(
      "events/batch-replay/phase-replayed.json",
      "schema_version" => 1, "event_id" => "phase-replayed", "batch_id" => "batch-replay",
      "type" => "phase", "repo" => "shakacode/example", "target" => "replay", "phase" => "qa", "at" => old_at
    )
    write_state_record(
      "events/batch-replay/lane_closed-first.json",
      valid_gc_lane_closed(
        event_id: "lane_closed-first", batch_id: "batch-replay", target: "replay", at: old_at
      )
    )
    replay_stdout = StringIO.new
    replay_runner = AgentCoord::Runner.new([], stdout: replay_stdout, clock: FixedClock.new(now))

    assert_equal 0, replay_runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    archive_paths = Dir.glob(File.join(@state_root, "archive/events/batch-replay/*.json"))
    assert_equal 2, archive_paths.length
    assert_includes archive_paths, first_path
    assert_equal first_bytes, File.binread(first_path)
    action = JSON.parse(replay_stdout.string).fetch("actions").find { |row| row["action"] == "compact" }
    refute_equal first_path.delete_prefix("#{@state_root}/"), action.fetch("archive_path")
  end

  def test_gc_generation_identity_includes_canonical_source_content
    now = Time.utc(2026, 7, 20, 12, 0, 0)
    old_at = (now - (8 * 86_400)).iso8601
    source_path = "events/batch-content/lane_closed-stable.json"
    original = valid_gc_lane_closed(
      event_id: "lane_closed-stable", batch_id: "batch-content", target: "content", at: old_at
    )
    write_state_record(source_path, original)
    runner = AgentCoord::Runner.new([], stdout: StringIO.new, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    first_path = Dir.glob(File.join(@state_root, "archive/events/batch-content/*.json")).fetch(0)
    first_bytes = File.binread(first_path)

    write_state_record(source_path, original.to_a.reverse.to_h)
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    assert_equal [first_path], Dir.glob(File.join(@state_root, "archive/events/batch-content/*.json"))
    assert_equal first_bytes, File.binread(first_path)

    changed = original.merge("terminal" => "superseded", "at" => (Time.iso8601(old_at) + 1).iso8601)
    write_state_record(source_path, changed)
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: false, execute: true, json: true)
    archive_paths = Dir.glob(File.join(@state_root, "archive/events/batch-content/*.json"))
    assert_equal 2, archive_paths.length
    assert_includes archive_paths, first_path
    assert_equal first_bytes, File.binread(first_path)
  end

  def test_gc_datetime_validation_matches_published_rfc3339_timezone_requirement
    schema = JSONSchemer.schema(JSON.parse(File.read(File.join(ROOT, "contracts/state-schema-v2.json"))))
    fixture = JSON.parse(File.read(File.join(ROOT, "contracts/fixtures/v2/lane_closed.json")))
    runner = AgentCoord::Runner.new([])
    cases = {
      "2026-07-12T01:07:00" => false,
      "2026-07-12T01:07:00Z" => true,
      "2026-07-12T01:07:00+10:30" => true,
      "2026-07-12t01:07:00z" => true
    }

    cases.each do |value, expected|
      schema_valid = schema.validate(fixture.merge("at" => value)).to_a.empty?
      assert_equal expected, schema_valid, "schema comparison for #{value}"
      assert_equal schema_valid, runner.send(:gc_valid_datetime?, value), "runtime comparison for #{value}"
    end
  end

  def test_status_excludes_archive_by_default_and_includes_it_only_when_requested
    write_state_record(
      "archive/claims/shakacode/example/old.json",
      "schema_version" => 1,
      "record_family" => "archived_record",
      "source_path" => "claims/shakacode/example/old.json",
      "reason" => "terminal_claim",
      "synthetic" => false,
      "archived_at" => "2026-07-01T00:00:00Z",
      "delete_after" => "2026-07-31T00:00:00Z",
      "data" => { "schema_version" => 1, "repo" => "shakacode/example", "target" => "old" }
    )

    default_status = run_agent_coord("status", "--json")
    archive_status = run_agent_coord("status", "--json", "--include-archived")

    assert_equal 0, default_status.status.exitstatus, default_status.stderr
    assert_equal 0, archive_status.status.exitstatus, archive_status.stderr
    refute JSON.parse(default_status.stdout).key?("archive")
    archived = JSON.parse(archive_status.stdout).fetch("archive")
    assert_equal 1, archived.length
    assert_equal "archive/claims/shakacode/example/old.json", archived.first.fetch("path")
    assert_equal "claims/shakacode/example/old.json", archived.first.fetch("source_path")
  end

  def test_status_reports_non_directory_root_parent_without_backtrace
    parent = File.join(@state_root, "state-parent-file")
    File.write(parent, "not a directory")

    result = run_agent_coord("status", state_root: File.join(parent, "state"))

    assert_equal 2, result.status.exitstatus
    assert_empty result.stdout
    assert_includes result.stderr, "state root is not accessible"
    refute_includes result.stderr, "bin/agent-coord:"
  end

  def test_status_reports_permission_denied_root_without_backtrace
    restricted = File.join(@state_root, "restricted-parent")
    state_root = File.join(restricted, "state")
    FileUtils.mkdir_p(state_root)
    FileUtils.chmod(0o000, restricted)
    skip "filesystem permissions are not enforced for this user" if File.stat(state_root)
  rescue Errno::EACCES
    result = run_agent_coord("status", state_root: state_root)

    assert_equal 2, result.status.exitstatus
    assert_empty result.stdout
    assert_includes result.stderr, "state root is not accessible"
    refute_includes result.stderr, "bin/agent-coord:"
  ensure
    FileUtils.chmod(0o755, restricted) if restricted && File.exist?(restricted)
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
    assert_includes doctor.stdout, "--stack-json  emit the versioned component report for stack aggregators"
  end

  def test_status_help_omits_doctor_only_deep_option
    result = run_agent_coord("status", "--help", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stdout, "--deep"
    refute_includes result.stdout, "--doctor-prefix"
    refute_includes result.stdout, "--stack-json"
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
    assert_equal 1, payload.fetch("archive_schema_version")
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
    assert_equal(
      { "hot_days" => 7, "archive_days" => 30, "synthetic_hot_days" => 1 },
      payload.fetch("retention_policy")
    )
    assert_includes payload.fetch("dependency_terminal_statuses"), "done"
    assert_includes payload.fetch("dependency_terminal_statuses"), "ready_gates_clean"
    assert_includes payload.fetch("dependency_terminal_statuses"), "completed"
    refute_includes payload.fetch("dependency_terminal_statuses"), "released"
    refute_includes payload.fetch("dependency_terminal_statuses"), "abandoned"
    vocabulary = payload.fetch("heartbeat_status_vocabulary")
    assert_equal AgentCoord::HEARTBEAT_WORKING_STATUSES, vocabulary.fetch("working")
    assert_equal AgentCoord::HEARTBEAT_TERMINAL_STATUSES, vocabulary.fetch("terminal")
    assert_equal "done", vocabulary.fetch("aliases").fetch("completed")
    assert_equal "in_progress", vocabulary.fetch("aliases").fetch("in_process")
    refute vocabulary.fetch("aliases").key?("released"),
           "released must not alias to a dependency-satisfying status; it can mean handoff"
    assert_equal 3, payload.fetch("exit_codes").fetch("claim_refused")
    assert_equal 2, payload.fetch("exit_codes").fetch("operational")
    assert_equal 64, payload.fetch("exit_codes").fetch("stack_usage")
    refute payload.key?("doctor_prefix_supplied")
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

  def test_legacy_local_deep_doctor_prefix_still_audits_all_state
    FileUtils.mkdir_p(File.join(@state_root, "heartbeats"))
    File.write(File.join(@state_root, "heartbeats", "broken.json"), "{")

    result = run_agent_coord("doctor", "--deep", "--doctor-prefix", "claims")

    assert_equal 2, result.status.exitstatus
    assert_includes result.stderr, "state unreadable"
    refute_includes result.stdout, "status: ok"
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

  def test_stack_doctor_contains_unexpected_resource_failure_without_leaking_details
    secret = "resource-secret-value"
    store = Class.new do
      def initialize(message)
        @message = message
      end

      def verify_layout!(_prefixes); end

      def list_json(_prefix)
        raise @message
      end
    end.new(secret)
    stdout = StringIO.new
    stderr = StringIO.new
    runner = AgentCoord::Runner.new(
      ["doctor", "--stack-json", "--deep", "--api-url", "https://coordination.invalid"],
      stdout:, stderr:
    )
    runner.define_singleton_method(:build_store) { |_options| store }
    runner.define_singleton_method(:close_store) { |_store| nil }

    assert_equal 2, runner.run
    assert_empty stderr.string
    report = JSON.parse(stdout.string)
    resource_check = report.fetch("checks").find { |check| check.fetch("id") == "resources.deep" }
    assert_equal "failed", report.fetch("status")
    assert_equal "failed", resource_check.fetch("status")
    assert_equal "Unexpected resource-check failure", resource_check.dig("details", "error")
    assert_equal "RuntimeError", resource_check.dig("details", "error_class")
    refute_includes stdout.string, secret
  end

  def test_stack_doctor_contains_unexpected_backend_failure_without_leaking_details
    secret = "backend-secret-value"
    store = Class.new do
      def initialize(message)
        @message = message
      end

      def verify_layout!(_prefixes)
        raise TypeError, @message
      end
    end.new(secret)
    stdout = StringIO.new
    stderr = StringIO.new
    runner = AgentCoord::Runner.new(
      ["doctor", "--stack-json", "--deep", "--api-url", "https://coordination.invalid"],
      stdout:, stderr:
    )
    runner.define_singleton_method(:build_store) { |_options| store }
    runner.define_singleton_method(:close_store) { |_store| nil }

    assert_equal 2, runner.run
    assert_empty stderr.string
    report = JSON.parse(stdout.string)
    backend_check = report.fetch("checks").find { |check| check.fetch("id") == "backend.readability" }
    resource_check = report.fetch("checks").find { |check| check.fetch("id") == "resources.deep" }
    assert_equal "failed", report.fetch("status")
    assert_equal "failed", backend_check.fetch("status")
    assert_equal "Unexpected backend-readability failure", backend_check.dig("details", "error")
    assert_equal "TypeError", backend_check.dig("details", "error_class")
    assert_equal "skipped", resource_check.fetch("status")
    assert_equal "deep", resource_check.dig("details", "mode")
    assert_equal "backend_unavailable", resource_check.dig("details", "reason")
    refute_includes stdout.string, secret
    refute_includes stdout.string, __method__.to_s
  end

  def test_stack_backend_details_never_report_nonlocal_state_root
    runner = AgentCoord::Runner.new([])
    options = {
      backend: "example/coordination",
      api_url: "https://coordination.invalid",
      state_root: "/ambient/state"
    }

    %w[github http].each do |backend_kind|
      details = runner.send(:stack_backend_details, options, backend_kind)

      assert_nil details.fetch("state_root"), backend_kind
    end
  end

  def test_stack_doctor_preserves_escaping_operational_error_contract
    stdout = StringIO.new
    stderr = StringIO.new
    failure = AgentCoord::OperationalError.new("escaped backend failure")
    runner = AgentCoord::Runner.new(
      ["doctor", "--stack-json", "--state-root", @state_root],
      stdout:, stderr:
    )
    runner.define_singleton_method(:doctor) { |_options| raise failure }

    raised = assert_raises(AgentCoord::OperationalError) { runner.run }

    assert_same failure, raised
    assert_equal AgentCoord::EXIT_OPERATIONAL, raised.exit_code
    assert_empty stdout.string
    assert_empty stderr.string
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

  def test_doctor_rejects_archived_github_backend_before_reporting_healthy
    fake_bin = Dir.mktmpdir("agent-coord-gh-archived")
    write_fake_gh(fake_bin, archived: true)

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
        "shakacode/agent-coordination-state"
      )

      assert_equal 2, result.status.exitstatus
      assert_includes result.stderr, "is archived and read-only"
      assert_includes result.stderr, "AGENT_COORD_API_URL"
      assert_includes result.stderr, "AGENT_COORD_API_TOKEN"
      refute_includes result.stdout, "status: ok"
    end
  ensure
    FileUtils.remove_entry(fake_bin) if fake_bin && Dir.exist?(fake_bin)
  end

  def test_stack_doctor_rejects_archived_github_backend
    fake_bin = Dir.mktmpdir("agent-coord-gh-archived-stack")
    write_fake_gh(fake_bin, archived: true)

    with_agent_coord_without_source_state do |bin|
      stack_result = run_command(
        {
          "AGENT_COORD_STATE_ROOT" => nil,
          "AGENT_COORD_STATUS_STATE_ROOT" => nil,
          "PATH" => [fake_bin, File.dirname(RbConfig.ruby)].join(File::PATH_SEPARATOR)
        },
        RbConfig.ruby,
        bin,
        "doctor",
        "--stack-json",
        "--backend",
        "shakacode/agent-coordination-state"
      )
      assert_equal 2, stack_result.status.exitstatus
      assert_empty stack_result.stderr
      stack_report = JSON.parse(stack_result.stdout)
      assert_equal "failed", stack_report.fetch("status")
      backend_check = stack_report.fetch("checks").find { |check| check.fetch("id") == "backend.readability" }
      assert_includes backend_check.dig("details", "error"), "is archived and read-only"
    end
  ensure
    FileUtils.remove_entry(fake_bin) if fake_bin && Dir.exist?(fake_bin)
  end

  def test_doctor_rejects_unreadable_archive_metadata
    fake_bin = Dir.mktmpdir("agent-coord-gh-archived-unreadable")
    write_fake_gh(fake_bin, archived: :unreadable)

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
        "shakacode/agent-coordination-state"
      )

      assert_equal 2, result.status.exitstatus
      assert_includes result.stderr, "metadata is not readable"
      refute_includes result.stdout, "status: ok"
    end
  ensure
    FileUtils.remove_entry(fake_bin) if fake_bin && Dir.exist?(fake_bin)
  end

  def test_doctor_rejects_archive_metadata_missing_archived_key
    fake_bin = Dir.mktmpdir("agent-coord-gh-archived-missing-key")
    write_fake_gh(fake_bin, archived: :missing_key)

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
        "shakacode/agent-coordination-state"
      )

      assert_equal 2, result.status.exitstatus
      assert_includes result.stderr, "does not report archived state"
      refute_includes result.stdout, "status: ok"
    end
  ensure
    FileUtils.remove_entry(fake_bin) if fake_bin && Dir.exist?(fake_bin)
  end

  def test_doctor_rejects_non_object_archive_metadata
    fake_bin = Dir.mktmpdir("agent-coord-gh-archived-not-object")
    write_fake_gh(fake_bin, archived: :not_object)

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
        "shakacode/agent-coordination-state"
      )

      assert_equal 2, result.status.exitstatus
      assert_includes result.stderr, "does not report archived state"
      refute_includes result.stderr, "NoMethodError"
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

  def test_launch_prompt_option_is_register_batch_only
    prompt_path = File.join(@state_root, "launch-prompt.txt")
    File.write(prompt_path, "Do not attach this to a claim.\n")

    result = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4151",
      "--launch-prompt", prompt_path
    )

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "--launch-prompt is only valid for register-batch"
    refute_path_exists File.join(@state_root, "claims", "shakacode", "react_on_rails", "4151.json")
  end

  def test_doctor_help_accepts_deep_option
    result = run_agent_coord("doctor", "--deep", "--help", state_root: nil)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "--deep"
    assert_includes result.stdout, "--doctor-prefix"
    assert_includes result.stdout, "--stack-json  emit the versioned component report for stack aggregators"
  end

  def test_non_doctor_deep_guard_ignores_deep_as_option_value
    commands = [
      ["status", "--branch", "--deep", "--json"],
      ["release", "--agent-id", "a", "--repo", "o/r", "--target", "1", "--terminal", "--deep"],
      ["release", "--agent-id", "a", "--repo", "o/r", "--target", "1", "--pr-state", "--deep"],
      ["release", "--agent-id", "a", "--repo", "o/r", "--target", "1", "--evidence-url", "--deep"],
      ["release", "--agent-id", "a", "--repo", "o/r", "--target", "1", "--workspace", "--deep"],
      ["release", "--agent-id", "a", "--repo", "o/r", "--target", "1", "--handoff-note", "--deep"],
      ["gc", "--dry-run", "--hot-d", "--deep"]
    ]
    commands.each do |args|
      result = run_agent_coord(*args)
      refute_includes result.stderr, "--deep is only valid for doctor"
    end
  end

  def test_standalone_option_detector_does_not_resolve_swallowed_value
    runner = AgentCoord::Runner.new([])
    resolver = runner.method(:resolve_standalone_option)
    resolved_names = []
    runner.define_singleton_method(:resolve_standalone_option) do |option_name, command_options, target_options|
      resolved_names << option_name
      resolver.call(option_name, command_options, target_options)
    end

    count = runner.send(
      :standalone_option_token_count,
      ["--branch", "--deep", "--deep"],
      ["--deep"],
      command: "status"
    )

    assert_equal 1, count
    assert_equal %w[--branch --deep], resolved_names
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

  def test_readme_documents_heartbeat_status_vocabulary
    readme = File.read(File.join(ROOT, "README.md"))

    assert_includes readme, "### Heartbeat status vocabulary"
    AgentCoord::HEARTBEAT_STATUSES.each do |status|
      assert_includes readme, "`#{status}`"
    end
    AgentCoord::HEARTBEAT_STATUS_ALIASES.each_key do |alias_value|
      assert_includes readme, "`#{alias_value}`"
    end
    assert_includes readme, "`status_raw`"
    assert_includes readme, "heartbeat_status_vocabulary"
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

  def test_local_store_concurrent_readers_never_observe_partial_json
    store = AgentCoord::LocalStore.new(@state_root)
    path = "batches/atomic.json"
    store.write_json(path, { "sequence" => 0, "payload" => "x" * 100_000 }, message: "seed", create: true)
    ready = Queue.new
    start = Queue.new
    observed = Queue.new
    acknowledged = Queue.new
    writer = Thread.new do
      4.times { ready.pop }
      4.times { start << true }
      4.times { acknowledged.pop }
      50.times do |sequence|
        current = store.read_json(path)
        store.write_json(path, { "sequence" => sequence, "payload" => "x" * 100_000 },
                         message: "update", sha: current.sha)
      end
    end
    readers = 4.times.map do
      Thread.new do
        ready << true
        start.pop
        initial = store.read_json(path).data.fetch("sequence")
        observed << initial
        acknowledged << true
        199.times { store.read_json(path) }
      end
    end
    thread_values!([writer] + readers, "atomic LocalStore readers/writer")

    final = store.read_json(path).data
    assert_equal [0, 0, 0, 0], 4.times.map { observed.pop }.sort
    assert_equal 49, final.fetch("sequence")
    assert_equal 100_000, final.fetch("payload").length
  end

  def test_local_store_lists_missing_root_and_nested_prefix_as_healthy_empty_without_mutation
    missing_root = File.join(@state_root, "missing-root")
    assert_empty AgentCoord::LocalStore.new(missing_root).list_json("claims")
    refute_path_exists missing_root

    claims = File.join(@state_root, "claims")
    FileUtils.mkdir_p(claims)
    assert_empty AgentCoord::LocalStore.new(@state_root).list_json("claims/missing")
    assert_equal ["claims"], Dir.children(@state_root)
    assert_empty Dir.children(claims)
  end

  def test_local_store_list_ignores_hidden_files_and_directories
    visible_path = "claims/shakacode/example/visible.json"
    write_state_record(visible_path, "schema_version" => 1, "visible" => true)
    claims = File.join(@state_root, "claims")
    File.write(File.join(claims, ".broken.json"), "{")
    hidden_directory = File.join(claims, ".cache")
    FileUtils.mkdir_p(hidden_directory)
    File.write(File.join(hidden_directory, "broken.json"), "{")

    entries = AgentCoord::LocalStore.new(@state_root).list_json("claims")

    assert_equal [visible_path], entries.map(&:path)
    assert entries.fetch(0).data.fetch("visible")
  end

  def test_local_store_fsyncs_leaf_directory_after_atomic_rename
    store = ObservedDirectoryFsyncLocalStore.new(@state_root)
    store.write_json("batches/durable.json", { "ok" => true }, message: "durable", create: true)

    assert store.target_existed_during_fsync
    assert_equal [File.join(@state_root, "batches")], store.fsynced_directories
  end

  def test_local_store_tolerates_known_unsupported_directory_fsync
    store = UnsupportedDirectoryFsyncLocalStore.new(@state_root)

    store.write_json("batches/unsupported.json", { "ok" => true }, message: "durable", create: true)

    assert store.read_json("batches/unsupported.json").data.fetch("ok")
  end

  def test_local_store_propagates_unexpected_directory_fsync_errors
    store = FailingDirectoryFsyncLocalStore.new(@state_root)

    assert_raises(Errno::EACCES) do
      store.write_json("batches/failing.json", { "ok" => true }, message: "durable", create: true)
    end
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

  def test_heartbeat_coerces_terminal_synonym_status_and_projects_status_raw
    result = run_agent_coord("heartbeat", "--agent-id", "worker-vocab", "--status", "completed")

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stderr, "warning: status"
    heartbeat = read_heartbeat("worker-vocab")
    assert_equal "done", heartbeat.fetch("status")
    assert_equal "completed", heartbeat.fetch("status_raw")

    status = run_agent_coord("status", "--json")
    assert_equal 0, status.status.exitstatus, status.stderr
    projected = JSON.parse(status.stdout).fetch("heartbeats").first
    assert_equal "done", projected.fetch("status")
    assert_equal "completed", projected.fetch("status_raw")
  end

  def test_heartbeat_coerces_hyphen_and_case_twin_status_to_snake_case
    result = run_agent_coord("heartbeat", "--agent-id", "worker-vocab", "--status", "Waiting-On-Checks-Or-Review")

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stderr, "warning: status"
    heartbeat = read_heartbeat("worker-vocab")
    assert_equal "waiting_on_checks_or_review", heartbeat.fetch("status")
    assert_equal "Waiting-On-Checks-Or-Review", heartbeat.fetch("status_raw")
  end

  def test_heartbeat_coerces_spelling_twin_status
    result = run_agent_coord("heartbeat", "--agent-id", "worker-vocab", "--status", "in_process")

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stderr, "warning: status"
    heartbeat = read_heartbeat("worker-vocab")
    assert_equal "in_progress", heartbeat.fetch("status")
    assert_equal "in_process", heartbeat.fetch("status_raw")
  end

  def test_heartbeat_preserves_unknown_status_verbatim_with_warning
    result = run_agent_coord("heartbeat", "--agent-id", "worker-vocab", "--status", "merged_pr_94")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "heartbeat worker-vocab"
    assert_includes result.stderr, 'warning: status "merged_pr_94" is not in the canonical status vocabulary'
    heartbeat = read_heartbeat("worker-vocab")
    assert_equal "merged_pr_94", heartbeat.fetch("status")
    assert_equal "merged_pr_94", heartbeat.fetch("status_raw")
  end

  def test_heartbeat_released_status_stays_verbatim_and_does_not_unblock_dependents
    write_batch(
      "batch-handoff-released",
      lanes: [{ "name" => "backend", "owner" => "worker-handoff", "targets" => ["4210"] }]
    )
    write_batch(
      "batch-handoff-consumer",
      lanes: [
        {
          "name" => "docs",
          "owner" => "worker-waiting",
          "targets" => ["4211"],
          "depends_on" => ["batch-handoff-released:backend"]
        }
      ]
    )
    released = run_agent_coord("heartbeat", "--agent-id", "worker-handoff", "--status", "released")
    blocked = run_agent_coord("heartbeat", "--agent-id", "worker-waiting", "--status", "blocked")

    assert_equal 0, released.status.exitstatus, released.stderr
    assert_equal 0, blocked.status.exitstatus, blocked.stderr
    assert_includes released.stderr, 'warning: status "released" is not in the canonical status vocabulary'
    heartbeat = read_heartbeat("worker-handoff")
    assert_equal "released", heartbeat.fetch("status")
    assert_equal "released", heartbeat.fetch("status_raw")

    status = run_agent_coord("status", "--batch-id", "batch-handoff-consumer", "--json")
    assert_equal 0, status.status.exitstatus, status.stderr
    consumer = JSON.parse(status.stdout).fetch("batches").first.fetch("lanes").first
    assert_equal ["batch-handoff-released:backend"], consumer.fetch("blocked_on"),
                 "expected a released heartbeat written through the CLI to stay non-completing"
  end

  def test_heartbeat_canonical_status_passes_through_without_status_raw_or_warning
    result = run_agent_coord("heartbeat", "--agent-id", "worker-vocab", "--status", "ready_gates_clean")

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stderr, "warning: status"
    heartbeat = read_heartbeat("worker-vocab")
    assert_equal "ready_gates_clean", heartbeat.fetch("status")
    refute heartbeat.key?("status_raw"), "expected status_raw to be absent"
  end

  def test_heartbeat_renewal_with_canonical_status_clears_stale_status_raw
    first = run_agent_coord("heartbeat", "--agent-id", "worker-vocab", "--status", "merged_pr_94")
    assert_equal 0, first.status.exitstatus, first.stderr

    renewal = run_agent_coord("heartbeat", "--agent-id", "worker-vocab", "--status", "done")

    assert_equal 0, renewal.status.exitstatus, renewal.stderr
    refute_includes renewal.stderr, "warning: status"
    heartbeat = read_heartbeat("worker-vocab")
    assert_equal "done", heartbeat.fetch("status")
    refute heartbeat.key?("status_raw"), "expected stale status_raw to be cleared"
  end

  def test_heartbeat_records_environment_machine_and_codex_session_identity
    secret = "secret-token-value-do-not-leak"
    result = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity", "--repo", "shakacode/react_on_rails", "--target", "62",
      env: {
        "AGENT_COORD_MACHINE_ID" => "m5",
        "CODEX_THREAD_ID" => "codex-thread-42",
        "AGENT_COORD_API_TOKEN" => secret
      }
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    raw = File.read(File.join(@state_root, "heartbeats", "worker-identity.json"))
    heartbeat = JSON.parse(raw)
    assert_equal "m5", heartbeat.fetch("machine_id")
    assert_equal "codex-thread-42", heartbeat.fetch("session_id")
    assert_equal "codex_thread_id", heartbeat.fetch("session_source")
    refute_includes raw, secret
    refute_includes result.stdout + result.stderr, secret

    status = run_agent_coord("status", "--json")
    assert_equal 0, status.status.exitstatus, status.stderr
    projected = JSON.parse(status.stdout).fetch("heartbeats").first
    assert_equal "m5", projected.fetch("machine_id")
    assert_equal "codex-thread-42", projected.fetch("session_id")
    assert_equal "codex_thread_id", projected.fetch("session_source")
  end

  def test_heartbeat_prefers_explicit_session_id_over_codex_thread_id
    result = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: {
        "AGENT_COORD_MACHINE_ID" => "m1-codex",
        "AGENT_COORD_SESSION_ID" => "explicit-run-7",
        "CODEX_THREAD_ID" => "codex-thread-42"
      }
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-identity.json")))
    assert_equal "m1-codex", heartbeat.fetch("machine_id")
    assert_equal "explicit-run-7", heartbeat.fetch("session_id")
    assert_equal "agent_coord_session_id", heartbeat.fetch("session_source")
  end

  def test_heartbeat_without_identity_environment_omits_identity_fields
    result = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "  ", "AGENT_COORD_SESSION_ID" => "", "CODEX_THREAD_ID" => " " }
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-identity.json")))
    %w[machine_id session_id session_source].each do |field|
      refute heartbeat.key?(field), "expected #{field} to be absent"
    end
  end

  def test_heartbeat_renewal_preserves_identity_until_new_environment_overrides_it
    first = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42" }
    )
    assert_equal 0, first.status.exitstatus, first.stderr

    renewal = run_agent_coord("heartbeat", "--agent-id", "worker-identity")
    assert_equal 0, renewal.status.exitstatus, renewal.stderr
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-identity.json")))
    assert_equal "m5", heartbeat.fetch("machine_id")
    assert_equal "codex-thread-42", heartbeat.fetch("session_id")
    assert_equal "codex_thread_id", heartbeat.fetch("session_source")

    takeover = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m1-codex", "AGENT_COORD_SESSION_ID" => "explicit-run-7" }
    )
    assert_equal 0, takeover.status.exitstatus, takeover.stderr
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-identity.json")))
    assert_equal "m1-codex", heartbeat.fetch("machine_id")
    assert_equal "explicit-run-7", heartbeat.fetch("session_id")
    assert_equal "agent_coord_session_id", heartbeat.fetch("session_source")
  end

  def test_cross_machine_heartbeat_renewal_clears_stale_session_identity
    first = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42" }
    )
    assert_equal 0, first.status.exitstatus, first.stderr

    renewal = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m1-codex" }
    )
    assert_equal 0, renewal.status.exitstatus, renewal.stderr
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-identity.json")))
    assert_equal "m1-codex", heartbeat.fetch("machine_id")
    %w[session_id session_source].each do |field|
      refute heartbeat.key?(field), "expected stale #{field} to be cleared on a machine change"
    end
  end

  def test_same_machine_heartbeat_renewal_preserves_session_identity
    first = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42" }
    )
    assert_equal 0, first.status.exitstatus, first.stderr

    renewal = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m5" }
    )
    assert_equal 0, renewal.status.exitstatus, renewal.stderr
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-identity.json")))
    assert_equal "m5", heartbeat.fetch("machine_id")
    assert_equal "codex-thread-42", heartbeat.fetch("session_id")
    assert_equal "codex_thread_id", heartbeat.fetch("session_source")
  end

  def test_cross_machine_heartbeat_renewal_with_session_writes_the_new_tuple
    first = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42" }
    )
    assert_equal 0, first.status.exitstatus, first.stderr

    renewal = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m1-codex", "AGENT_COORD_SESSION_ID" => "explicit-run-7" }
    )
    assert_equal 0, renewal.status.exitstatus, renewal.stderr
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-identity.json")))
    assert_equal "m1-codex", heartbeat.fetch("machine_id")
    assert_equal "explicit-run-7", heartbeat.fetch("session_id")
    assert_equal "agent_coord_session_id", heartbeat.fetch("session_source")
  end

  def test_cross_machine_claim_renewal_clears_stale_session_identity
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-identity", "--repo", "shakacode/react_on_rails", "--target", "62",
      env: { "AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42" }
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    renewal = run_agent_coord(
      "claim", "--agent-id", "worker-identity", "--repo", "shakacode/react_on_rails", "--target", "62",
      env: { "AGENT_COORD_MACHINE_ID" => "m1-codex" }
    )
    assert_equal 0, renewal.status.exitstatus, renewal.stderr
    claim_payload = JSON.parse(File.read(File.join(@state_root, "claims", "shakacode", "react_on_rails", "62.json")))
    assert_equal "m1-codex", claim_payload.fetch("machine_id")
    %w[session_id session_source].each do |field|
      refute claim_payload.key?(field), "expected stale #{field} to be cleared on a machine change"
    end
  end

  def test_cross_session_heartbeat_renewal_without_machine_clears_stale_machine_identity
    first = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42" }
    )
    assert_equal 0, first.status.exitstatus, first.stderr

    renewal = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_SESSION_ID" => "explicit-run-7" }
    )
    assert_equal 0, renewal.status.exitstatus, renewal.stderr
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-identity.json")))
    assert_equal "explicit-run-7", heartbeat.fetch("session_id")
    assert_equal "agent_coord_session_id", heartbeat.fetch("session_source")
    refute heartbeat.key?("machine_id"), "expected the stale machine_id to be cleared on a session change"
  end

  def test_same_session_heartbeat_renewal_without_machine_preserves_machine_identity
    first = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42" }
    )
    assert_equal 0, first.status.exitstatus, first.stderr

    renewal = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "CODEX_THREAD_ID" => "codex-thread-42" }
    )
    assert_equal 0, renewal.status.exitstatus, renewal.stderr
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-identity.json")))
    assert_equal "m5", heartbeat.fetch("machine_id")
    assert_equal "codex-thread-42", heartbeat.fetch("session_id")
    assert_equal "codex_thread_id", heartbeat.fetch("session_source")
  end

  def test_session_only_renewal_after_machine_only_write_clears_the_stale_machine
    first = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_MACHINE_ID" => "m5" }
    )
    assert_equal 0, first.status.exitstatus, first.stderr

    renewal = run_agent_coord(
      "heartbeat", "--agent-id", "worker-identity",
      env: { "AGENT_COORD_SESSION_ID" => "explicit-run-7" }
    )
    assert_equal 0, renewal.status.exitstatus, renewal.stderr
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-identity.json")))
    assert_equal "explicit-run-7", heartbeat.fetch("session_id")
    refute heartbeat.key?("machine_id"),
           "expected the machine-only attribution to be cleared when a new session cannot attest it"
  end

  def test_cross_machine_terminal_release_keeps_claim_and_event_identity_consistent
    write_batch(
      "batch-identity",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["62"] }]
    )
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "62",
      "--batch-id", "batch-identity", "--host", "codex",
      env: { "AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42" }
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    release = run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "62",
      "--terminal", "done", "--pr-state", "merged",
      env: { "AGENT_COORD_MACHINE_ID" => "m1-codex" }
    )
    assert_equal 0, release.status.exitstatus, release.stderr

    claim_payload = JSON.parse(File.read(File.join(@state_root, "claims", "shakacode", "react_on_rails", "62.json")))
    event = event_of_type("batch-identity", "lane_closed")
    assert_equal "m1-codex", claim_payload.fetch("machine_id")
    assert_equal "m1-codex", event.fetch("machine_id")
    assert_equal({ "agent_id" => "worker-a", "machine" => "m1-codex" }, event.fetch("closed_by"))
    assert_equal event.fetch("closed_by"), claim_payload.fetch("closed_by")
    %w[session_id session_source].each do |field|
      refute claim_payload.key?(field), "expected stale claim #{field} to be cleared on a machine change"
      refute event.key?(field), "expected the lane_closed event to omit #{field} without session environment"
    end
  end

  def test_claim_and_release_record_environment_identity
    identity_env = { "AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42" }
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-identity", "--repo", "shakacode/react_on_rails", "--target", "62",
      env: identity_env
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "62.json")
    claim_payload = JSON.parse(File.read(claim_path))
    assert_equal "m5", claim_payload.fetch("machine_id")
    assert_equal "codex-thread-42", claim_payload.fetch("session_id")
    assert_equal "codex_thread_id", claim_payload.fetch("session_source")

    status = run_agent_coord("status", "--repo", "shakacode/react_on_rails", "--target", "62", "--json")
    assert_equal 0, status.status.exitstatus, status.stderr
    projected = JSON.parse(status.stdout).fetch("claims").first
    assert_equal "m5", projected.fetch("machine_id")
    assert_equal "codex-thread-42", projected.fetch("session_id")

    release = run_agent_coord(
      "release", "--agent-id", "worker-identity", "--repo", "shakacode/react_on_rails", "--target", "62"
    )
    assert_equal 0, release.status.exitstatus, release.stderr
    released_payload = JSON.parse(File.read(claim_path))
    assert_equal "released", released_payload.fetch("status")
    assert_equal "m5", released_payload.fetch("machine_id")
    assert_equal "codex-thread-42", released_payload.fetch("session_id")
  end

  def test_terminal_release_uses_environment_machine_id_for_closed_by
    write_batch(
      "batch-identity",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["62"] }]
    )
    identity_env = { "AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42" }
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "62",
      "--batch-id", "batch-identity", "--branch", "jg-codex/identity", "--host", "codex",
      env: identity_env
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    release = run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "62",
      "--terminal", "done", "--pr-state", "merged",
      env: identity_env
    )
    assert_equal 0, release.status.exitstatus, release.stderr

    event = event_of_type("batch-identity", "lane_closed")
    assert_equal({ "agent_id" => "worker-a", "machine" => "m5" }, event.fetch("closed_by"))
    assert_equal "m5", event.fetch("machine_id")
    assert_equal "codex-thread-42", event.fetch("session_id")
    assert_equal "codex_thread_id", event.fetch("session_source")
    contract = JSONSchemer.schema(JSON.parse(File.read(File.join(ROOT, "contracts", "state-schema-v2.json"))))
    assert_empty contract.validate(event).to_a

    claim_payload = JSON.parse(File.read(File.join(@state_root, "claims", "shakacode", "react_on_rails", "62.json")))
    assert_equal({ "agent_id" => "worker-a", "machine" => "m5" }, claim_payload.fetch("closed_by"))

    status = run_agent_coord("status", "--batch-id", "batch-identity", "--json")
    assert_equal 0, status.status.exitstatus, status.stderr
    status_event = JSON.parse(status.stdout).fetch("events").first
    assert_equal "m5", status_event.fetch("machine_id")
    assert_equal "codex-thread-42", status_event.fetch("session_id")
  end

  def test_deep_doctor_reports_environment_identity_for_local_backend
    identity_env = {
      "AGENT_COORD_MACHINE_ID" => "m5",
      "AGENT_COORD_SESSION_ID" => "explicit-run-7",
      "AGENT_COORD_API_TOKEN" => "secret-token-value-do-not-leak"
    }
    json_result = run_agent_coord("doctor", "--deep", "--json", env: identity_env)

    assert_equal 0, json_result.status.exitstatus, json_result.stderr
    identity = JSON.parse(json_result.stdout).fetch("environment_identity")
    assert_equal AgentCoord::VERSION, identity.fetch("client_version")
    assert_equal "m5", identity.fetch("machine_id")
    assert_equal "explicit-run-7", identity.fetch("session_id")
    assert_equal "agent_coord_session_id", identity.fetch("session_source")
    assert_nil identity.fetch("token_machine")
    assert_equal "unverified", identity.fetch("machine_match")
    refute_includes json_result.stdout + json_result.stderr, "secret-token-value-do-not-leak"

    text_result = run_agent_coord("doctor", "--deep", env: identity_env)
    assert_equal 0, text_result.status.exitstatus, text_result.stderr
    assert_includes text_result.stdout, "machine_id: m5"
    assert_includes text_result.stdout, "session_id: explicit-run-7"
    assert_includes text_result.stdout, "session_source: agent_coord_session_id"
    assert_includes text_result.stdout, "machine_match: unverified"
    refute_includes text_result.stdout + text_result.stderr, "secret-token-value-do-not-leak"
  end

  def test_deep_doctor_without_identity_environment_reports_unset_session
    result = run_agent_coord("doctor", "--deep", "--json")

    assert_equal 0, result.status.exitstatus, result.stderr
    identity = JSON.parse(result.stdout).fetch("environment_identity")
    assert_nil identity.fetch("machine_id")
    assert_nil identity.fetch("session_id")
    assert_equal "unset", identity.fetch("session_source")
    assert_equal "unverified", identity.fetch("machine_match")
  end

  def test_lightweight_doctor_omits_environment_identity_for_stable_output
    result = run_agent_coord("doctor", "--json", env: { "AGENT_COORD_MACHINE_ID" => "m5" })

    assert_equal 0, result.status.exitstatus, result.stderr
    refute JSON.parse(result.stdout).key?("environment_identity")

    text_result = run_agent_coord("doctor", env: { "AGENT_COORD_MACHINE_ID" => "m5" })
    assert_equal 0, text_result.status.exitstatus, text_result.stderr
    refute_includes text_result.stdout, "machine_id:"
  end

  def test_doctor_deep_http_reports_machine_match_and_token_identity
    with_identity_env("AGENT_COORD_MACHINE_ID" => "m5", "CODEX_THREAD_ID" => "codex-thread-42") do
      stdout = StringIO.new
      runner = doctor_identity_runner(stdout, token_machine: "m5")

      assert_equal 0, runner.run
      payload = JSON.parse(stdout.string)
      assert_equal "ok", payload.fetch("status")
      assert_equal "m5", payload.dig("identity", "machine")
      identity = payload.fetch("environment_identity")
      assert_equal "m5", identity.fetch("machine_id")
      assert_equal "codex-thread-42", identity.fetch("session_id")
      assert_equal "codex_thread_id", identity.fetch("session_source")
      assert_equal "m5", identity.fetch("token_machine")
      assert_equal "match", identity.fetch("machine_match")
    end
  end

  def test_doctor_deep_http_fails_on_machine_identity_mismatch
    with_identity_env("AGENT_COORD_MACHINE_ID" => "m5") do
      stdout = StringIO.new
      runner = doctor_identity_runner(stdout, token_machine: "m1-codex")

      error = assert_raises(AgentCoord::OperationalError) { runner.run }

      assert_equal AgentCoord::EXIT_OPERATIONAL, error.exit_code
      assert_includes error.message, "machine identity mismatch"
      assert_includes error.message, "AGENT_COORD_MACHINE_ID=m5"
      assert_includes error.message, "m1-codex"
      payload = JSON.parse(stdout.string)
      assert_equal "error", payload.fetch("status")
      identity = payload.fetch("environment_identity")
      assert_equal "mismatch", identity.fetch("machine_match")
      assert_equal "m1-codex", identity.fetch("token_machine")
    end
  end

  def test_doctor_deep_http_without_environment_machine_reports_unverified
    with_identity_env({}) do
      stdout = StringIO.new
      runner = doctor_identity_runner(stdout, token_machine: "m5")

      assert_equal 0, runner.run
      identity = JSON.parse(stdout.string).fetch("environment_identity")
      assert_nil identity.fetch("machine_id")
      assert_equal "unset", identity.fetch("session_source")
      assert_equal "m5", identity.fetch("token_machine")
      assert_equal "unverified", identity.fetch("machine_match")
    end
  end

  def doctor_identity_runner(stdout, token_machine:)
    store = Class.new do
      def initialize(machine)
        @machine = machine
      end

      def verify_layout!(_prefixes); end

      def list_json(_prefix)
        []
      end

      def whoami
        { "machine" => @machine, "read_prefixes" => ["*"], "write_prefixes" => ["*"] }
      end
    end.new(token_machine)
    runner = AgentCoord::Runner.new(
      ["doctor", "--deep", "--api-url", "https://coordination.invalid", "--json"],
      stdout:, stderr: StringIO.new
    )
    runner.define_singleton_method(:build_store) { |_options| store }
    runner.define_singleton_method(:close_store) { |_store| nil }
    runner
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

    event = event_of_type("batch-terminal", "lane_closed")
    assert_equal 2, event.fetch("schema_version")
    assert_equal "lane_closed", event.fetch("type")
    assert_equal "code", event.fetch("lane")
    assert_equal "done", event.fetch("terminal")
    assert_equal "default", event.fetch("workspace")
    assert_equal({ "agent_id" => "worker-a", "machine" => "codex" }, event.fetch("closed_by"))
    assert_equal "merged", event.fetch("pr_state")
    assert_mixed_case_terminal_urls(event)
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

  def assert_mixed_case_terminal_urls(event)
    assert_equal "HTTPS://github.com/shakacode/react_on_rails/pull/3980", event.fetch("pr_url")
    assert_equal "HtTpS://example.test/evidence/3980", event.fetch("evidence_url")
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
    assert_equal "legacy", event_of_type("batch-legacy-id", "lane_closed").fetch("lane")
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
    thread_values!(threads, "concurrent batch terminal releases")

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
    thread_values!(threads, "concurrent lane_closed events")
    event_paths = Dir.glob(File.join(@state_root, "events", batch_id, "*.json"))
    assert_equal 1, event_paths.length
    event = JSON.parse(File.read(event_paths.fetch(0)))
    assert_equal event.fetch("event_id"), File.basename(event_paths.fetch(0), ".json")
    batch = JSON.parse(File.read(File.join(@state_root, "batches", "#{batch_id}.json")))
    [results, errors, event, batch]
  end

  def test_claim_acquire_with_batch_id_records_claim_acquired_event
    write_batch("batch-lifecycle", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4100"] }])
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4100",
      "--batch-id", "batch-lifecycle", "--branch", "jg/lifecycle", "--host", "codex",
      "--phase", "implementing", "--generation", "2", "--instance-id", "instance-a"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    event = event_of_type("batch-lifecycle", "claim.acquired")
    assert_equal "batch-lifecycle", event.fetch("batch_id")
    assert_equal "worker-a", event.fetch("agent_id")
    assert_equal "shakacode/react_on_rails", event.fetch("repo")
    assert_equal "4100", event.fetch("target")
    assert_equal "jg/lifecycle", event.fetch("branch")
    assert_equal "implementing", event.fetch("phase")
    assert_equal 2, event.fetch("generation")
    assert_equal "instance-a", event.fetch("instance_id")
    assert_match(/\A\d{8}T\d{6}\.\d{6}Z-[0-9a-f]{8}\z/, event.fetch("event_id"))
    refute event.key?("status"), "expected claim.acquired to omit a status snapshot"
  end

  def test_claim_acquire_without_batch_id_records_no_event
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4101",
      "--phase", "implementing"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr
    refute_path_exists File.join(@state_root, "events")
  end

  def test_claim_acquire_tolerates_event_write_failure
    write_batch("batch-acquire-fail", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4102"] }])
    FileUtils.mkdir_p(File.join(@state_root, "events"))
    File.write(File.join(@state_root, "events", "batch-acquire-fail"), "not a directory")

    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4102",
      "--batch-id", "batch-acquire-fail"
    )

    assert_equal 0, claim.status.exitstatus, claim.stderr
    assert_includes claim.stderr, "warning: claim.acquired event not recorded"
    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "4102.json")
    assert_equal "active", JSON.parse(File.read(claim_path)).fetch("status")
  end

  def test_claim_same_holder_renewal_records_no_additional_claim_acquired_event
    write_batch("batch-renewal", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4160"] }])
    args = [
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4160",
      "--batch-id", "batch-renewal", "--branch", "jg/renewal", "--generation", "1", "--instance-id", "instance-a"
    ]
    first = run_agent_coord(*args)
    assert_equal 0, first.status.exitstatus, first.stderr
    second = run_agent_coord(*args)
    assert_equal 0, second.status.exitstatus, second.stderr

    assert_equal 1, events_of_type("batch-renewal", "claim.acquired").length
  end

  def test_claim_after_release_re_emits_claim_acquired_event
    write_batch("batch-reacquire", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4161"] }])
    base = [
      "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "4161", "--batch-id", "batch-reacquire"
    ]
    assert_equal 0, run_agent_coord("claim", *base).status.exitstatus
    assert_equal 0, run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4161"
    ).status.exitstatus
    assert_equal 0, run_agent_coord("claim", *base).status.exitstatus

    assert_equal 2, events_of_type("batch-reacquire", "claim.acquired").length
  end

  def test_claim_with_changed_generation_re_emits_claim_acquired_event
    write_batch("batch-generation", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4162"] }])
    common = [
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4162",
      "--batch-id", "batch-generation"
    ]
    assert_equal 0, run_agent_coord(*common, "--generation", "1").status.exitstatus
    assert_equal 0, run_agent_coord(*common, "--generation", "2").status.exitstatus

    assert_equal 2, events_of_type("batch-generation", "claim.acquired").length
  end

  def test_claim_renewal_that_adds_instance_id_re_emits_claim_acquired_event
    write_batch("batch-add-instance", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4191"] }])
    common = [
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4191",
      "--batch-id", "batch-add-instance"
    ]
    assert_equal 0, run_agent_coord(*common).status.exitstatus
    assert_equal 0, run_agent_coord(*common, "--instance-id", "instance-a").status.exitstatus

    assert_equal 2, events_of_type("batch-add-instance", "claim.acquired").length
  end

  def test_release_records_claim_released_event_with_final_status
    write_batch("batch-release", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4130"] }])
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4130",
      "--batch-id", "batch-release", "--branch", "jg/release"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr

    release = run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4130"
    )
    assert_equal 0, release.status.exitstatus, release.stderr

    event = event_of_type("batch-release", "claim.released")
    assert_equal "worker-a", event.fetch("agent_id")
    assert_equal "shakacode/react_on_rails", event.fetch("repo")
    assert_equal "4130", event.fetch("target")
    assert_equal "jg/release", event.fetch("branch")
    assert_equal "released", event.fetch("status")
    refute event.key?("status_raw"), "expected the released-status snapshot to bypass status coercion"
    refute event.key?("release_mode"), "expected a plain release to omit release_mode"
    refute event.key?("handoff_to"), "expected a plain release to omit handoff fields"
  end

  def test_release_tolerates_event_write_failure
    write_batch("batch-release-fail", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4131"] }])
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4131",
      "--batch-id", "batch-release-fail"
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr
    # Replace the event directory (created by claim.acquired) with a plain file
    # so the release's claim.released event write fails.
    FileUtils.rm_rf(File.join(@state_root, "events", "batch-release-fail"))
    File.write(File.join(@state_root, "events", "batch-release-fail"), "not a directory")

    release = run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4131"
    )

    assert_equal 0, release.status.exitstatus, release.stderr
    assert_includes release.stderr, "warning: claim.released event not recorded"
    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "4131.json")
    assert_equal "released", JSON.parse(File.read(claim_path)).fetch("status")
  end

  def test_heartbeat_phase_transition_emits_single_phase_changed_event
    args = [
      "heartbeat", "--agent-id", "worker-a", "--batch-id", "batch-phase",
      "--repo", "shakacode/react_on_rails", "--target", "4120", "--status", "in_progress"
    ]
    base = run_agent_coord(*args, "--phase", "implementing")
    assert_equal 0, base.status.exitstatus, base.stderr
    # The first phase assignment is not a transition; claim.acquired records the
    # initial phase, so a heartbeat with no prior phase emits nothing.
    assert_empty events_of_type("batch-phase", "phase.changed")

    changed = run_agent_coord(*args, "--phase", "validating")
    assert_equal 0, changed.status.exitstatus, changed.stderr

    repeat = run_agent_coord(*args, "--phase", "validating")
    assert_equal 0, repeat.status.exitstatus, repeat.stderr

    event = event_of_type("batch-phase", "phase.changed")
    assert_equal "batch-phase", event.fetch("batch_id")
    assert_equal "worker-a", event.fetch("agent_id")
    assert_equal "implementing", event.fetch("previous_phase")
    assert_equal "validating", event.fetch("phase")
    assert_equal "phase implementing -> validating", event.fetch("message")
  end

  def test_heartbeat_repeated_phase_records_no_event
    args = [
      "heartbeat", "--agent-id", "worker-a", "--batch-id", "batch-phase-same",
      "--repo", "shakacode/react_on_rails", "--target", "4121", "--phase", "validating", "--status", "in_progress"
    ]
    first = run_agent_coord(*args)
    assert_equal 0, first.status.exitstatus, first.stderr
    second = run_agent_coord(*args)
    assert_equal 0, second.status.exitstatus, second.stderr

    assert_empty events_of_type("batch-phase-same", "phase.changed")
  end

  def test_heartbeat_without_batch_id_records_no_phase_changed_event
    common = [
      "heartbeat", "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails", "--target", "4122", "--status", "in_progress"
    ]
    assert_equal 0, run_agent_coord(*common, "--phase", "implementing").status.exitstatus
    assert_equal 0, run_agent_coord(*common, "--phase", "validating").status.exitstatus
    refute_path_exists File.join(@state_root, "events")
  end

  def test_heartbeat_phase_change_tolerates_event_write_failure
    common = [
      "heartbeat", "--agent-id", "worker-a", "--batch-id", "batch-phase-fail",
      "--repo", "shakacode/react_on_rails", "--target", "4123", "--status", "in_progress"
    ]
    first = run_agent_coord(*common, "--phase", "implementing")
    assert_equal 0, first.status.exitstatus, first.stderr
    FileUtils.mkdir_p(File.join(@state_root, "events"))
    File.write(File.join(@state_root, "events", "batch-phase-fail"), "not a directory")

    second = run_agent_coord(*common, "--phase", "validating")

    assert_equal 0, second.status.exitstatus, second.stderr
    assert_includes second.stderr, "warning: phase.changed event not recorded"
    heartbeat = JSON.parse(File.read(File.join(@state_root, "heartbeats", "worker-a.json")))
    assert_equal "validating", heartbeat.fetch("phase")
  end

  def test_heartbeat_lane_switch_does_not_fabricate_phase_changed_event
    # The per-agent heartbeat record is reused across lanes; a beat that switches
    # to a different batch/target must not compare phases across lanes and write a
    # bogus transition into the new batch.
    first = run_agent_coord(
      "heartbeat", "--agent-id", "worker-a", "--batch-id", "batch-lane-a",
      "--repo", "shakacode/react_on_rails", "--target", "4150", "--phase", "implementing", "--status", "in_progress"
    )
    assert_equal 0, first.status.exitstatus, first.stderr

    second = run_agent_coord(
      "heartbeat", "--agent-id", "worker-a", "--batch-id", "batch-lane-b",
      "--repo", "shakacode/react_on_rails", "--target", "4151", "--phase", "validating", "--status", "in_progress"
    )
    assert_equal 0, second.status.exitstatus, second.stderr

    assert_empty events_of_type("batch-lane-a", "phase.changed")
    assert_empty events_of_type("batch-lane-b", "phase.changed")
  end

  def test_phase_changed_inherits_preserved_heartbeat_metadata
    args = [
      "heartbeat", "--agent-id", "worker-a", "--batch-id", "batch-phase-meta",
      "--repo", "shakacode/react_on_rails", "--target", "4170", "--status", "in_progress"
    ]
    first = run_agent_coord(*args, "--phase", "implementing", "--synthetic", "--synthetic-kind", "simulation")
    assert_equal 0, first.status.exitstatus, first.stderr
    # The transition supplies only --phase; synthetic/synthetic_kind must be
    # inherited from the overwritten heartbeat record onto the phase.changed event
    # so the batch's lifecycle history keeps the short synthetic GC retention.
    second = run_agent_coord(*args, "--phase", "validating")
    assert_equal 0, second.status.exitstatus, second.stderr

    event = event_of_type("batch-phase-meta", "phase.changed")
    assert_equal "validating", event.fetch("phase")
    assert_equal "implementing", event.fetch("previous_phase")
    assert_equal true, event.fetch("synthetic")
    assert_equal "simulation", event.fetch("synthetic_kind")
  end

  def test_status_json_projects_phase_changed_previous_phase
    write_batch("batch-phase-status", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4180"] }])
    args = [
      "heartbeat", "--agent-id", "worker-a", "--batch-id", "batch-phase-status",
      "--repo", "shakacode/react_on_rails", "--target", "4180", "--status", "in_progress"
    ]
    assert_equal 0, run_agent_coord(*args, "--phase", "implementing").status.exitstatus
    assert_equal 0, run_agent_coord(*args, "--phase", "validating").status.exitstatus

    status = run_agent_coord("status", "--batch-id", "batch-phase-status", "--json")
    assert_equal 0, status.status.exitstatus, status.stderr
    event = JSON.parse(status.stdout).fetch("events").find { |projected| projected["type"] == "phase.changed" }
    refute_nil event, "expected a phase.changed event in the status projection"
    assert_equal "implementing", event.fetch("previous_phase")
    assert_equal "validating", event.fetch("phase")
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

    assert_equal 1, events_of_type("batch-handoff", "claim.acquired").length
    event = event_of_type("batch-handoff", "claim.released")
    assert_handoff_release_event(event)

    status = run_agent_coord("status", "--batch-id", "batch-handoff", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    status_event = JSON.parse(status.stdout).fetch("events").find { |projected| projected["type"] == "claim.released" }
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
    assert_includes release.stderr, "warning: claim.released event not recorded"
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
    # Replace the event directory (created by the claim.acquired auto-emit) with a
    # plain file so the release's claim.released event write fails.
    FileUtils.rm_rf(File.join(@state_root, "events", "batch-file"))
    File.write(File.join(@state_root, "events", "batch-file"), "not a directory")

    release = run_agent_coord(
      "release",
      "--agent-id", "worker-a",
      "--repo", "shakacode/react_on_rails",
      "--target", "3980",
      "--handoff-note", "Continue elsewhere."
    )

    assert_equal 0, release.status.exitstatus, release.stderr
    assert_includes release.stderr, "warning: claim.released event not recorded"
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
      "--status", "blocked"
    )
    assert_equal 0, retargeted.status.exitstatus, retargeted.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/agent-workflows", heartbeat_payload.fetch("repo")
    assert_equal "76", heartbeat_payload.fetch("target")
    assert_equal "blocked", heartbeat_payload.fetch("status")
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
      "--status", "blocked"
    )
    assert_equal 0, retargeted.status.exitstatus, retargeted.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/react_on_rails", heartbeat_payload.fetch("repo")
    assert_equal "3980", heartbeat_payload.fetch("target")
    assert_equal "batch-2", heartbeat_payload.fetch("batch_id")
    assert_equal "blocked", heartbeat_payload.fetch("status")
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
      "--status", "blocked"
    )
    assert_equal 0, retargeted.status.exitstatus, retargeted.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/react_on_rails", heartbeat_payload.fetch("repo")
    assert_equal "3982", heartbeat_payload.fetch("target")
    assert_equal "batch-2", heartbeat_payload.fetch("batch_id")
    assert_equal "blocked", heartbeat_payload.fetch("status")
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
      "--status", "blocked"
    )
    assert_equal 0, repo_only.status.exitstatus, repo_only.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/agent-workflows", heartbeat_payload.fetch("repo")
    refute heartbeat_payload.key?("target"), "expected target to be absent"
    assert_equal "blocked", heartbeat_payload.fetch("status")
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
      "--status", "blocked"
    )
    assert_equal 0, repo_only.status.exitstatus, repo_only.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/react_on_rails", heartbeat_payload.fetch("repo")
    refute heartbeat_payload.key?("target"), "expected target to be absent"
    assert_equal "blocked", heartbeat_payload.fetch("status")
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
      "--status", "blocked"
    )
    assert_equal 0, target_specific.status.exitstatus, target_specific.stderr

    heartbeat_path = File.join(@state_root, "heartbeats", "worker-a.json")
    heartbeat_payload = JSON.parse(File.read(heartbeat_path))
    assert_equal "shakacode/react_on_rails", heartbeat_payload.fetch("repo")
    assert_equal "3985", heartbeat_payload.fetch("target")
    assert_equal "blocked", heartbeat_payload.fetch("status")
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

  def test_register_batch_persists_and_renews_synthetic_metadata_for_one_day_gc
    now = Time.utc(2026, 7, 12, 12, 0, 0)
    manifest_path = File.join(@state_root, "synthetic-batch.json")
    File.write(
      manifest_path,
      JSON.generate(
        "batch_id" => "synthetic-batch", "status" => "active",
        "lanes" => [{ "name" => "simulation", "owner" => "sim-worker", "targets" => ["sim"] }]
      )
    )
    first = run_agent_coord(
      "register-batch", "--file", manifest_path, "--synthetic", "--synthetic-kind", "simulation"
    )
    renewal = run_agent_coord("register-batch", "--file", manifest_path)
    assert_equal 0, first.status.exitstatus, first.stderr
    assert_equal 0, renewal.status.exitstatus, renewal.stderr
    batch_path = File.join(@state_root, "batches/synthetic-batch.json")
    batch = JSON.parse(File.read(batch_path))
    assert_equal true, batch.fetch("synthetic")
    assert_equal "simulation", batch.fetch("synthetic_kind")
    batch["status"] = "completed"
    batch["completed_at"] = (now - (2 * 86_400)).iso8601
    batch["updated_at"] = batch.fetch("completed_at")
    File.write(batch_path, JSON.pretty_generate(batch))

    stdout = StringIO.new
    runner = AgentCoord::Runner.new([], stdout: stdout, clock: FixedClock.new(now))
    assert_equal 0, runner.send(:gc, state_root: @state_root, dry_run: true, execute: false, json: true)
    actions = JSON.parse(stdout.string).fetch("actions")
    action = actions.find { |row| row["source_path"] == "batches/synthetic-batch.json" }
    assert_equal "archive", action.fetch("action")
  end

  def test_register_batch_reads_launch_prompt_from_path_and_overrides_manifest
    manifest_path = File.join(@state_root, "batch-manifest.json")
    prompt_path = File.join(@state_root, "launch-prompt.txt")
    File.write(
      manifest_path,
      JSON.pretty_generate(
        "batch_id" => "batch-launch-prompt-path",
        "launch_prompt" => "stale manifest prompt",
        "lanes" => [{ "name" => "docs", "owner" => "worker-docs", "targets" => ["3972"] }]
      )
    )
    File.write(prompt_path, "Coordinate this exact batch.\n")

    result = run_agent_coord("register-batch", "--file", manifest_path, "--launch-prompt", prompt_path)

    assert_equal 0, result.status.exitstatus, result.stderr
    stored = JSON.parse(File.read(File.join(@state_root, "batches", "batch-launch-prompt-path.json")))
    assert_equal "Coordinate this exact batch.\n", stored.fetch("launch_prompt")
  end

  def test_register_batch_reads_launch_prompt_from_stdin
    manifest_path = File.join(@state_root, "batch-manifest.json")
    File.write(
      manifest_path,
      JSON.pretty_generate(
        "batch_id" => "batch-launch-prompt-stdin",
        "lanes" => [{ "name" => "docs", "owner" => "worker-docs", "targets" => ["3972"] }]
      )
    )

    result = run_agent_coord(
      "register-batch", "--file", manifest_path, "--launch-prompt", "-",
      stdin_data: "Coordinate the batch from stdin.\n"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    stored = JSON.parse(File.read(File.join(@state_root, "batches", "batch-launch-prompt-stdin.json")))
    assert_equal "Coordinate the batch from stdin.\n", stored.fetch("launch_prompt")
  end

  def test_register_batch_reports_unreadable_launch_prompt_without_writing_batch
    manifest_path = File.join(@state_root, "batch-manifest.json")
    File.write(
      manifest_path,
      JSON.pretty_generate(
        "batch_id" => "batch-missing-launch-prompt",
        "lanes" => [{ "name" => "docs", "owner" => "worker-docs", "targets" => ["3972"] }]
      )
    )

    result = run_agent_coord(
      "register-batch", "--file", manifest_path,
      "--launch-prompt", File.join(@state_root, "missing-prompt.txt")
    )

    assert_equal 2, result.status.exitstatus
    assert_includes result.stderr, "launch prompt unreadable"
    refute_path_exists File.join(@state_root, "batches", "batch-missing-launch-prompt.json")
  end

  def test_register_batch_rejects_invalid_utf8_launch_prompts_before_writing
    invalid_prompt = "\xFF".b
    prompt_path = File.join(@state_root, "invalid-launch-prompt.txt")
    File.binwrite(prompt_path, invalid_prompt)

    { "path" => [prompt_path, nil], "stdin" => ["-", invalid_prompt] }.each do |source, (argument, stdin_data)|
      batch_id = "batch-invalid-launch-prompt-#{source}"
      manifest_path = File.join(@state_root, "#{batch_id}.json")
      File.write(
        manifest_path,
        JSON.pretty_generate(
          "batch_id" => batch_id,
          "lanes" => [{ "name" => "docs", "owner" => "worker-docs", "targets" => ["3972"] }]
        )
      )

      result = run_agent_coord(
        "register-batch", "--file", manifest_path, "--launch-prompt", argument,
        stdin_data: stdin_data
      )

      assert_equal 1, result.status.exitstatus, source
      assert_includes result.stderr, "launch prompt must be valid UTF-8", source
      refute_includes result.stderr, "JSON::GeneratorError", source
      refute_path_exists File.join(@state_root, "batches", "#{batch_id}.json"), source
    end
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

  def test_record_event_coerces_alias_status_and_projects_status_raw
    write_batch("batch-vocab", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3990"] }])

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-vocab", "--type", "phase",
      "--agent-id", "worker-a", "--status", "ready-to-merge"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stderr, "warning: status"
    event_files = Dir.glob(File.join(@state_root, "events", "batch-vocab", "*.json"))
    assert_equal 1, event_files.length
    event = JSON.parse(File.read(event_files.first))
    assert_equal "ready", event.fetch("status")
    assert_equal "ready-to-merge", event.fetch("status_raw")

    status = run_agent_coord("status", "--batch-id", "batch-vocab", "--json")
    assert_equal 0, status.status.exitstatus, status.stderr
    status_event = JSON.parse(status.stdout).fetch("events").first
    assert_equal "ready", status_event.fetch("status")
    assert_equal "ready-to-merge", status_event.fetch("status_raw")
  end

  def test_record_event_preserves_unknown_status_verbatim_with_warning
    write_batch("batch-vocab", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3990"] }])

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-vocab", "--type", "phase",
      "--agent-id", "worker-a", "--status", "pushed_review_fix_6"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "recorded event batch-vocab"
    assert_includes result.stderr, 'warning: status "pushed_review_fix_6" is not in the canonical status vocabulary'
    event_files = Dir.glob(File.join(@state_root, "events", "batch-vocab", "*.json"))
    assert_equal 1, event_files.length
    event = JSON.parse(File.read(event_files.first))
    assert_equal "pushed_review_fix_6", event.fetch("status")
    assert_equal "pushed_review_fix_6", event.fetch("status_raw")
  end

  def test_record_event_canonical_status_writes_without_status_raw
    write_batch("batch-vocab", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3990"] }])

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-vocab", "--type", "phase",
      "--agent-id", "worker-a", "--status", "external_gate_failing"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stderr, "warning: status"
    event = JSON.parse(File.read(Dir.glob(File.join(@state_root, "events", "batch-vocab", "*.json")).first))
    assert_equal "external_gate_failing", event.fetch("status")
    refute event.key?("status_raw"), "expected status_raw to be absent"
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

    host_replay = args.dup
    host_replay[host_replay.index("--host") + 1] = "claude-code"
    replayed_from_other_host = run_agent_coord(*host_replay)
    assert_equal 0, replayed_from_other_host.status.exitstatus, replayed_from_other_host.stderr
    assert_includes replayed_from_other_host.stdout, "already closed"
    assert_equal 1, Dir.glob(event_glob).length
    assert_equal original_batch, File.read(batch_path)
  end

  def test_terminal_replay_rejects_foreign_agent_after_lane_owner_is_rewritten
    write_batch(
      "batch-cross-agent-terminal-replay",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3993"] }]
    )
    args = [
      "record-event", "--batch-id", "batch-cross-agent-terminal-replay", "--type", "lane_closed",
      "--lane", "code", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3993", "--host", "codex", "--terminal", "done",
      "--pr-url", "https://github.com/shakacode/react_on_rails/pull/3993", "--pr-state", "merged"
    ]
    first = run_agent_coord(*args)
    assert_equal 0, first.status.exitstatus, first.stderr

    event_glob = File.join(@state_root, "events", "batch-cross-agent-terminal-replay", "*.json")
    batch_path = File.join(@state_root, "batches", "batch-cross-agent-terminal-replay.json")
    original_event = File.read(Dir.glob(event_glob).fetch(0))

    foreign_replay = args.dup
    foreign_replay[foreign_replay.index("--agent-id") + 1] = "worker-b"
    foreign_env = { "AGENT_COORD_MACHINE_ID" => "m5" }
    rejected_by_identity = run_agent_coord(*foreign_replay, env: foreign_env)
    assert_equal 1, rejected_by_identity.status.exitstatus
    assert_includes rejected_by_identity.stderr, "terminal closeout agent does not match lane"

    rewritten_batch = JSON.parse(File.read(batch_path))
    rewritten_batch.fetch("lanes").fetch(0)["owner"] = "worker-b"
    File.write(batch_path, JSON.pretty_generate(rewritten_batch))
    original_rewritten_batch = File.read(batch_path)

    rejected_by_terminal_conflict = run_agent_coord(*foreign_replay, env: foreign_env)

    assert_equal 1, rejected_by_terminal_conflict.status.exitstatus
    assert_includes rejected_by_terminal_conflict.stderr, "conflicting terminal closeout"
    assert_equal 1, Dir.glob(event_glob).length
    assert_equal original_event, File.read(Dir.glob(event_glob).fetch(0))
    assert_equal original_rewritten_batch, File.read(batch_path)
  end

  def test_terminal_replay_stays_idempotent_when_machine_id_env_appears
    write_batch(
      "batch-machine-replay",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3995"] }]
    )
    args = [
      "record-event", "--batch-id", "batch-machine-replay", "--type", "lane_closed",
      "--lane", "code", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3995", "--host", "codex", "--terminal", "done",
      "--pr-url", "https://github.com/shakacode/react_on_rails/pull/3995", "--pr-state", "merged"
    ]
    first = run_agent_coord(*args)
    assert_equal 0, first.status.exitstatus, first.stderr
    event_glob = File.join(@state_root, "events", "batch-machine-replay", "*.json")
    batch_path = File.join(@state_root, "batches", "batch-machine-replay.json")
    original_event = File.read(Dir.glob(event_glob).fetch(0))
    original_batch = File.read(batch_path)
    assert_equal "codex", JSON.parse(original_event).dig("closed_by", "machine")

    replay = run_agent_coord(*args, env: { "AGENT_COORD_MACHINE_ID" => "m5" })

    assert_equal 0, replay.status.exitstatus, replay.stderr
    assert_includes replay.stdout, "already closed"
    assert_equal original_event, File.read(Dir.glob(event_glob).fetch(0))
    assert_equal original_batch, File.read(batch_path)
  end

  def test_terminal_replay_stays_idempotent_when_machine_id_env_disappears
    write_batch(
      "batch-machine-replay",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3995"] }]
    )
    args = [
      "record-event", "--batch-id", "batch-machine-replay", "--type", "lane_closed",
      "--lane", "code", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3995", "--host", "codex", "--terminal", "done",
      "--pr-url", "https://github.com/shakacode/react_on_rails/pull/3995", "--pr-state", "merged"
    ]
    first = run_agent_coord(*args, env: { "AGENT_COORD_MACHINE_ID" => "m5" })
    assert_equal 0, first.status.exitstatus, first.stderr
    event_glob = File.join(@state_root, "events", "batch-machine-replay", "*.json")
    original_event = File.read(Dir.glob(event_glob).fetch(0))
    assert_equal "m5", JSON.parse(original_event).dig("closed_by", "machine")

    replay = run_agent_coord(*args)

    assert_equal 0, replay.status.exitstatus, replay.stderr
    assert_includes replay.stdout, "already closed"
    assert_equal original_event, File.read(Dir.glob(event_glob).fetch(0))
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
    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3991.json")
    batch_path = File.join(@state_root, "batches", "batch-sticky-release.json")
    originals = [File.read(claim_path), File.read(batch_path)]

    replay = run_agent_coord(*args)

    assert_equal 0, replay.status.exitstatus, replay.stderr
    assert_includes replay.stdout, "already closed"
    assert_equal 1, events_of_type("batch-sticky-release", "lane_closed").length
    assert_equal originals, [File.read(claim_path), File.read(batch_path)]

    conflicting = args.dup
    conflicting[conflicting.index("--evidence-url") + 1] = "https://example.test/evidence/replaced"
    conflict = run_agent_coord(*conflicting)

    assert_equal 1, conflict.status.exitstatus
    assert_includes conflict.stderr, "conflicting terminal closeout"
    assert_equal 1, events_of_type("batch-sticky-release", "lane_closed").length
    assert_equal originals, [File.read(claim_path), File.read(batch_path)]
  end

  def test_terminal_release_replay_reconciles_legacy_claim_missing_closed_by
    write_batch(
      "batch-legacy-closed-by",
      lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["3995"] }]
    )
    identity_env = { "AGENT_COORD_MACHINE_ID" => "m5" }
    claim = run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3995", "--batch-id", "batch-legacy-closed-by", "--host", "codex",
      env: identity_env
    )
    assert_equal 0, claim.status.exitstatus, claim.stderr
    args = [
      "release", "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails",
      "--target", "3995", "--terminal", "done", "--pr-state", "merged"
    ]
    first = run_agent_coord(*args, env: identity_env)
    assert_equal 0, first.status.exitstatus, first.stderr

    claim_path = File.join(@state_root, "claims", "shakacode", "react_on_rails", "3995.json")
    closed = JSON.parse(File.read(claim_path))
    expected_closed_by = closed.fetch("closed_by")
    assert_equal "m5", expected_closed_by.fetch("machine")
    legacy = closed.except("closed_by", "machine_id", "session_id", "session_source")
    File.write(claim_path, JSON.generate(legacy))

    replay = run_agent_coord(*args, env: identity_env)
    assert_equal 0, replay.status.exitstatus, replay.stderr
    assert_includes replay.stdout, "released",
                    "expected the legacy claim to be reconciled from the authoritative event, " \
                    "not masked by live-environment reconstruction"
    reconciled = JSON.parse(File.read(claim_path))
    assert_equal expected_closed_by, reconciled.fetch("closed_by")

    second_replay = run_agent_coord(*args, env: identity_env)
    assert_equal 0, second_replay.status.exitstatus, second_replay.stderr
    assert_includes second_replay.stdout, "already closed"
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
    assert_equal 1, events_of_type("batch-partial-release", "lane_closed").length
    assert_equal authoritative_batch, File.read(batch_path)
  end

  def test_lane_closed_retry_reports_batch_reconciliation_from_seeded_event
    write_batch("batch-seeded-event", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["4014"] }])
    event_id = "lane_closed-#{Digest::SHA256.hexdigest('code')[0, 16]}"
    event_dir = File.join(@state_root, "events", "batch-seeded-event")
    FileUtils.mkdir_p(event_dir)
    event = {
      "schema_version" => 2, "event_id" => event_id, "batch_id" => "batch-seeded-event",
      "type" => "lane_closed", "lane" => "code", "agent_id" => "worker-a",
      "repo" => "shakacode/react_on_rails", "target" => "4014", "terminal" => "done",
      "workspace" => "default", "closed_by" => { "agent_id" => "worker-a", "machine" => "codex" },
      "at" => Time.now.utc.iso8601
    }
    File.write(File.join(event_dir, "#{event_id}.json"), JSON.pretty_generate(event))

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-seeded-event", "--type", "lane_closed", "--lane", "code",
      "--agent-id", "worker-a", "--repo", "shakacode/react_on_rails", "--target", "4014",
      "--host", "codex", "--terminal", "done"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "reconciled terminal closeout"
    refute_includes result.stdout, "already closed"
    assert_equal 1, Dir.glob(File.join(event_dir, "*.json")).length
    batch = JSON.parse(File.read(File.join(@state_root, "batches", "batch-seeded-event.json")))
    assert_equal "completed", batch.fetch("status")
    assert_equal "done", batch.fetch("lanes").fetch(0).fetch("terminal")
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
    thread_values!(threads, "concurrent same-claim releases")

    assert_empty errors
    assert_equal [0, 0], results.sort
    assert_equal 1, events_of_type("batch-same-claim", "lane_closed").length
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

  def test_record_event_error_persists_typed_fields_and_projects_status
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "error",
      "--severity", "P1", "--category", "ci-timeout", "--message", "gate timed out",
      "--agent-id", "worker-a", "--lane", "code"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    event = event_of_type("batch-typed", "error")
    assert_equal "P1", event.fetch("severity")
    assert_equal "ci-timeout", event.fetch("category")
    assert_equal "gate timed out", event.fetch("message")

    status = run_agent_coord("status", "--batch-id", "batch-typed", "--json")
    status_event = JSON.parse(status.stdout).fetch("events").first
    assert_equal "P1", status_event.fetch("severity")
    assert_equal "ci-timeout", status_event.fetch("category")
  end

  def test_record_event_error_requires_severity_category_and_message
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    missing_severity = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "error",
      "--category", "ci", "--message", "boom"
    )
    assert_equal 1, missing_severity.status.exitstatus
    assert_includes missing_severity.stderr, "missing required --severity"

    missing_category = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "error",
      "--severity", "P1", "--message", "boom"
    )
    assert_equal 1, missing_category.status.exitstatus
    assert_includes missing_category.stderr, "missing required --category"

    missing_message = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "error",
      "--severity", "P1", "--category", "ci"
    )
    assert_equal 1, missing_message.status.exitstatus
    assert_includes missing_message.stderr, "missing required --message"

    assert_empty event_records("batch-typed")
  end

  def test_record_event_error_rejects_invalid_severity
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "error",
      "--severity", "P9", "--category", "ci", "--message", "boom"
    )

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "--severity must be one of: P0, P1, P2, P3"
    assert_empty event_records("batch-typed")
  end

  def test_record_event_help_requested_happy_path
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "help_requested",
      "--reason", "blocked-user-input", "--agent-id", "worker-a"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal "blocked-user-input", event_of_type("batch-typed", "help_requested").fetch("reason")
  end

  def test_record_event_help_requested_requires_valid_reason
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    missing = run_agent_coord("record-event", "--batch-id", "batch-typed", "--type", "help_requested")
    assert_equal 1, missing.status.exitstatus
    assert_includes missing.stderr, "missing required --reason"

    invalid = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "help_requested", "--reason", "because"
    )
    assert_equal 1, invalid.status.exitstatus
    assert_includes invalid.stderr, "--reason must be one of: blocked-user-input, question, permission"
    assert_empty event_records("batch-typed")
  end

  def test_record_event_escalation_requested_happy_path
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "escalation_requested",
      "--from-route", "opus/high", "--to-route", "human", "--evidence", "gate red 3x",
      "--agent-id", "worker-a"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    event = event_of_type("batch-typed", "escalation_requested")
    assert_equal "opus/high", event.fetch("from_route")
    assert_equal "human", event.fetch("to_route")
    assert_equal "gate red 3x", event.fetch("evidence")
  end

  def test_record_event_escalation_requested_requires_all_fields
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "escalation_requested",
      "--from-route", "opus", "--to-route", "human"
    )

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "missing required --evidence"
    assert_empty event_records("batch-typed")
  end

  def test_record_event_rejects_whitespace_only_required_typed_fields_without_writing
    escalation_args = [
      "--from-route", "terra/high",
      "--to-route", "sol/xhigh",
      "--evidence", "Repeated integration failures require deeper diagnosis."
    ]
    error_args = [
      "--severity", "P1",
      "--category", "coordination-write",
      "--message", "Backend rejected the event append."
    ]
    cases = [
      ["from-route", "escalation_requested", escalation_args, 1],
      ["to-route", "escalation_requested", escalation_args, 3],
      ["evidence-summary", "escalation_requested", escalation_args, 5],
      ["category", "error", error_args, 3],
      ["description", "error", error_args, 5]
    ]
    outcomes = cases.each_with_index.map do |(name, type, valid_args, value_index), index|
      batch_id = "batch-typed-whitespace-#{index}"
      args = valid_args.dup
      args[value_index] = " \t "
      result = run_agent_coord("record-event", "--batch-id", batch_id, "--type", type, *args)
      {
        name: name,
        exit: result.status.exitstatus,
        event_count: event_records(batch_id).length,
        event_path_exists: Dir.exist?(File.join(@state_root, "events", batch_id))
      }
    end

    valid_controls = {
      "escalation" => ["escalation_requested", escalation_args],
      "error" => ["error", error_args]
    }.map do |name, (type, args)|
      batch_id = "batch-typed-whitespace-control-#{name}"
      result = run_agent_coord("record-event", "--batch-id", batch_id, "--type", type, *args)
      { name: name, exit: result.status.exitstatus, event_count: event_records(batch_id).length }
    end

    assert_equal 5, outcomes.length
    assert_empty(outcomes.reject do |outcome|
      outcome.values_at(:exit, :event_count, :event_path_exists) == [1, 0, false]
    end)
    assert_empty(valid_controls.reject do |outcome|
      outcome.values_at(:exit, :event_count) == [0, 1]
    end)
  end

  def test_record_event_human_intervention_happy_path
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "human_intervention",
      "--kind", "takeover", "--agent-id", "worker-a"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal "takeover", event_of_type("batch-typed", "human_intervention").fetch("kind")
  end

  def test_record_event_human_intervention_requires_valid_kind
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    missing = run_agent_coord("record-event", "--batch-id", "batch-typed", "--type", "human_intervention")
    assert_equal 1, missing.status.exitstatus
    assert_includes missing.stderr, "missing required --kind"

    invalid = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "human_intervention", "--kind", "reboot"
    )
    assert_equal 1, invalid.status.exitstatus
    assert_includes invalid.stderr, "--kind must be one of: takeover, supersede, manual-fix, drain"
    assert_empty event_records("batch-typed")
  end

  def test_record_event_arbitrary_type_skips_typed_field_validation
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    result = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "custom-note", "--agent-id", "worker-a"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    event = event_of_type("batch-typed", "custom-note")
    assert_empty event.keys & %w[reason from_route to_route evidence severity category kind]
  end

  def test_record_event_typed_type_rejects_foreign_typed_field
    write_batch("batch-typed", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    help_with_severity = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "help_requested",
      "--reason", "question", "--severity", "P1"
    )
    assert_equal 1, help_with_severity.status.exitstatus
    assert_includes help_with_severity.stderr, "--severity is not valid for --type help_requested"

    error_with_kind = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "error",
      "--severity", "P1", "--category", "ci", "--message", "boom", "--kind", "takeover"
    )
    assert_equal 1, error_with_kind.status.exitstatus
    assert_includes error_with_kind.stderr, "--kind is not valid for --type error"

    escalation_with_reason = run_agent_coord(
      "record-event", "--batch-id", "batch-typed", "--type", "escalation_requested",
      "--from-route", "a", "--to-route", "h", "--evidence", "e", "--reason", "question"
    )
    assert_equal 1, escalation_with_reason.status.exitstatus
    assert_includes escalation_with_reason.stderr, "--reason is not valid for --type escalation_requested"

    assert_empty event_records("batch-typed")
  end

  def test_batch_audit_reports_complete_batch
    write_batch(
      "batch-audit-ok",
      lanes: [
        { "name" => "code", "owner" => "worker-a", "targets" => ["101"] },
        { "name" => "docs", "owner" => "worker-b", "targets" => ["102"] }
      ]
    )
    seed_event("batch-audit-ok", "a1", "type" => "claim.acquired", "agent_id" => "worker-a")
    seed_event("batch-audit-ok", "a2", "type" => "claim.released", "agent_id" => "worker-a")
    seed_event("batch-audit-ok", "b1", "type" => "claim.acquired", "agent_id" => "worker-b")
    seed_event(
      "batch-audit-ok",
      "b2",
      "schema_version" => 2,
      "type" => "lane_closed",
      "agent_id" => "worker-b",
      "lane" => "docs",
      "repo" => "shakacode/example",
      "target" => "102",
      "terminal" => "done",
      "workspace" => "default",
      "closed_by" => { "agent_id" => "worker-b", "machine" => "test" }
    )

    result = run_agent_coord("batch-audit", "--batch-id", "batch-audit-ok")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "batch-audit batch-audit-ok complete"
    assert_includes result.stdout, "lane code owner worker-a complete"
    assert_includes result.stdout, "lane docs owner worker-b complete"
  end

  def test_batch_audit_rejects_invalid_or_conflicting_attributed_lane_closed_facts
    families = batch_audit_terminal_false_complete_families
    invalid_outcomes = invalid_terminal_audit_outcomes(families)
    control_outcomes = terminal_audit_control_outcomes

    assert_equal 12, families.length
    assert_equal 23, invalid_outcomes.length
    assert_equal 4, control_outcomes.length
    assert_empty(invalid_outcomes.reject do |outcome|
      outcome.values_at(:exit, :verdict, :complete) == [1, "incomplete", false] &&
        outcome.fetch(:missing).include?("terminal")
    end)
    assert_empty(control_outcomes.reject do |outcome|
      outcome.values_at(:exit, :verdict, :complete, :missing) == [0, "complete", true, []]
    end)
  end

  def test_batch_audit_rejects_malformed_ordinary_lifecycle_scalars
    invalid_outcomes = ordinary_lifecycle_scalar_cases.each_with_index.map do |(name, mutate), index|
      ordinary_lifecycle_audit_outcome(
        name, "batch-audit-lifecycle-scalar-#{index}", 8300 + index, mutate
      )
    end
    control_outcomes = ordinary_lifecycle_control_cases.each_with_index.map do |(name, mutate), index|
      ordinary_lifecycle_audit_outcome(
        name, "batch-audit-lifecycle-control-#{index}", 8400 + index, mutate
      )
    end

    assert_equal 9, invalid_outcomes.length
    assert_equal 4, control_outcomes.length
    assert_empty(invalid_outcomes.reject do |outcome|
      outcome.values_at(:exit, :verdict, :complete) == [1, "incomplete", false] &&
        !outcome.fetch(:missing).empty?
    end)
    assert_empty(control_outcomes.reject do |outcome|
      outcome.values_at(:exit, :verdict, :complete, :missing) == [0, "complete", true, []]
    end)
  end

  def test_batch_audit_flags_lane_gaps_with_exit_one
    write_batch(
      "batch-audit-gaps",
      lanes: [
        { "name" => "code", "owner" => "worker-a", "targets" => ["101"] },
        { "name" => "docs", "owner" => "worker-b", "targets" => ["102"] }
      ]
    )
    # code acquired but never reached a terminal signal; docs closed without an acquire event.
    seed_event("batch-audit-gaps", "a1", "type" => "claim.acquired", "agent_id" => "worker-a")
    seed_event("batch-audit-gaps", "b1", "type" => "claim.released", "agent_id" => "worker-b")

    result = run_agent_coord("batch-audit", "--batch-id", "batch-audit-gaps")
    assert_equal 1, result.status.exitstatus
    assert_includes result.stdout, "batch-audit batch-audit-gaps incomplete"
    assert_includes result.stdout, "lane code owner worker-a incomplete missing terminal"
    assert_includes result.stdout, "lane docs owner worker-b incomplete missing claim.acquired"

    json = run_agent_coord("batch-audit", "--batch-id", "batch-audit-gaps", "--json")
    assert_equal 1, json.status.exitstatus
    payload = JSON.parse(json.stdout)
    assert_equal "incomplete", payload.fetch("verdict")
    lanes = payload.fetch("lanes").to_h { |lane| [lane.fetch("name"), lane] }
    assert_equal ["terminal"], lanes.fetch("code").fetch("missing")
    refute lanes.fetch("code").fetch("complete")
    assert_equal ["claim.acquired"], lanes.fetch("docs").fetch("missing")
  end

  def test_batch_audit_flags_lane_with_no_events
    write_batch("batch-audit-empty", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])

    result = run_agent_coord("batch-audit", "--batch-id", "batch-audit-empty", "--json")

    assert_equal 1, result.status.exitstatus
    lane = JSON.parse(result.stdout).fetch("lanes").first
    assert_equal 0, lane.fetch("event_count")
    assert_equal ["claim.acquired", "terminal"], lane.fetch("missing")
    # Uniform lane schema: a normal lane carries the same "malformed" key as a
    # malformed lane entry, set to false, so downstream consumers see one shape.
    assert_equal false, lane.fetch("malformed")
  end

  def test_batch_audit_uses_auto_emitted_lifecycle_events
    write_batch("batch-audit-live", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])
    run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/x", "--target", "101",
      "--batch-id", "batch-audit-live", "--branch", "b-a"
    )

    incomplete = run_agent_coord("batch-audit", "--batch-id", "batch-audit-live")
    assert_equal 1, incomplete.status.exitstatus
    assert_includes incomplete.stdout, "incomplete missing terminal"

    run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/x", "--target", "101",
      "--batch-id", "batch-audit-live", "--branch", "b-a"
    )

    complete = run_agent_coord("batch-audit", "--batch-id", "batch-audit-live")
    assert_equal 0, complete.status.exitstatus, complete.stderr
    assert_includes complete.stdout, "batch-audit batch-audit-live complete"
  end

  def test_batch_audit_unregistered_batch_is_unknown
    result = run_agent_coord("batch-audit", "--batch-id", "missing-batch")
    assert_equal 2, result.status.exitstatus
    assert_includes result.stdout, "batch-audit missing-batch unknown"
    assert_includes result.stdout, "batch missing-batch is not registered"

    json = run_agent_coord("batch-audit", "--batch-id", "missing-batch", "--json")
    assert_equal 2, json.status.exitstatus
    payload = JSON.parse(json.stdout)
    assert_equal "unknown", payload.fetch("verdict")
    assert_empty payload.fetch("lanes")
  end

  def test_batch_audit_does_not_false_complete_lanes_sharing_an_owner
    write_batch(
      "batch-shared-owner",
      lanes: [
        { "name" => "lane-101", "owner" => "worker-a", "targets" => ["101"] },
        { "name" => "lane-102", "owner" => "worker-a", "targets" => ["102"] }
      ]
    )
    run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/x", "--target", "101",
      "--batch-id", "batch-shared-owner", "--branch", "b-a"
    )
    run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/x", "--target", "101",
      "--batch-id", "batch-shared-owner", "--branch", "b-a"
    )

    result = run_agent_coord("batch-audit", "--batch-id", "batch-shared-owner", "--json")

    assert_equal 1, result.status.exitstatus, result.stderr
    payload = JSON.parse(result.stdout)
    assert_equal "incomplete", payload.fetch("verdict")
    lanes = payload.fetch("lanes").to_h { |lane| [lane.fetch("name"), lane] }
    assert lanes.fetch("lane-101").fetch("complete"), "lane-101 (target 101) should be complete"
    assert_empty lanes.fetch("lane-101").fetch("missing")
    refute lanes.fetch("lane-102").fetch("complete"), "same-owner lane-102 (target 102) must not false-complete"
    assert_equal ["claim.acquired", "terminal"], lanes.fetch("lane-102").fetch("missing")
  end

  def test_batch_audit_defaults_to_status_state_root_without_global_state_root
    write_batch("batch-status-root", lanes: [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }])
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
      "batch-audit",
      "--batch-id",
      "batch-status-root"
    )

    assert_equal 1, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "batch-audit batch-status-root incomplete"
    refute_includes result.stderr, "local mode — single-machine only"
    refute_includes result.stderr, "unexpected gh"
  ensure
    FileUtils.remove_entry(fake_bin) if fake_bin && Dir.exist?(fake_bin)
  end

  def test_batch_audit_malformed_batch_id_is_unknown_not_incomplete
    result = run_agent_coord("batch-audit", "--batch-id", "../evil")
    assert_equal 2, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "batch-audit ../evil unknown"

    json = run_agent_coord("batch-audit", "--batch-id", "../evil", "--json")
    assert_equal 2, json.status.exitstatus
    assert_equal "unknown", JSON.parse(json.stdout).fetch("verdict")
  end

  def test_batch_audit_tolerates_malformed_lane_entry
    write_state_record(
      "batches/batch-null-lane.json",
      { "schema_version" => 1, "batch_id" => "batch-null-lane", "lanes" => [nil] }
    )

    result = run_agent_coord("batch-audit", "--batch-id", "batch-null-lane", "--json")

    assert_equal 1, result.status.exitstatus, result.stderr
    payload = JSON.parse(result.stdout)
    assert_equal "incomplete", payload.fetch("verdict")
    lane = payload.fetch("lanes").first
    refute lane.fetch("complete")
    assert lane.fetch("malformed")
    assert_equal ["claim.acquired", "terminal"], lane.fetch("missing")
  end

  def test_batch_audit_non_object_batch_state_is_unknown
    write_state_record("batches/batch-scalar.json", "not-an-object")

    result = run_agent_coord("batch-audit", "--batch-id", "batch-scalar")

    assert_equal 2, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "state is not an object"
  end

  def test_batch_audit_zero_lane_batch_is_unknown_not_complete
    write_state_record(
      "batches/batch-no-lanes.json",
      { "schema_version" => 1, "batch_id" => "batch-no-lanes", "lanes" => [] }
    )

    result = run_agent_coord("batch-audit", "--batch-id", "batch-no-lanes")
    assert_equal 2, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "batch-audit batch-no-lanes unknown"
    assert_includes result.stdout, "batch batch-no-lanes registers no lanes"

    json = run_agent_coord("batch-audit", "--batch-id", "batch-no-lanes", "--json")
    assert_equal 2, json.status.exitstatus
    assert_equal "unknown", JSON.parse(json.stdout).fetch("verdict")
  end

  def test_batch_audit_disambiguates_shared_target_by_owner
    write_batch(
      "batch-shared-target",
      lanes: [
        { "name" => "lane-a", "owner" => "worker-a", "targets" => ["101"] },
        { "name" => "lane-b", "owner" => "worker-b", "targets" => ["101"] }
      ]
    )
    run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/x", "--target", "101",
      "--batch-id", "batch-shared-target", "--branch", "b-a"
    )
    run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/x", "--target", "101",
      "--batch-id", "batch-shared-target", "--branch", "b-a"
    )

    result = run_agent_coord("batch-audit", "--batch-id", "batch-shared-target", "--json")

    assert_equal 1, result.status.exitstatus, result.stderr
    lanes = JSON.parse(result.stdout).fetch("lanes").to_h { |lane| [lane.fetch("name"), lane] }
    # Shared target 101 is ambiguous, so only the unique owner attributes the events.
    assert lanes.fetch("lane-a").fetch("complete"), "lane-a (owner worker-a) should be complete via unique owner"
    refute lanes.fetch("lane-b").fetch("complete"), "same-target lane-b must not false-complete"
    assert_equal ["claim.acquired", "terminal"], lanes.fetch("lane-b").fetch("missing")
  end

  def test_batch_audit_does_not_false_complete_lanes_sharing_target_and_owner
    write_batch(
      "batch-ambiguous",
      lanes: [
        { "name" => "lane-a", "owner" => "shared", "targets" => ["101"] },
        { "name" => "lane-b", "owner" => "shared", "targets" => ["101"] }
      ]
    )
    run_agent_coord(
      "claim", "--agent-id", "shared", "--repo", "shakacode/x", "--target", "101",
      "--batch-id", "batch-ambiguous", "--branch", "b"
    )
    run_agent_coord(
      "release", "--agent-id", "shared", "--repo", "shakacode/x", "--target", "101",
      "--batch-id", "batch-ambiguous", "--branch", "b"
    )

    result = run_agent_coord("batch-audit", "--batch-id", "batch-ambiguous", "--json")

    assert_equal 1, result.status.exitstatus, result.stderr
    payload = JSON.parse(result.stdout)
    assert_equal "incomplete", payload.fetch("verdict")
    # Neither target nor owner is unique, so no lane may be credited (fail-closed).
    payload.fetch("lanes").each do |lane|
      refute lane.fetch("complete"), "#{lane.fetch('name')} must stay incomplete when nothing disambiguates it"
    end
  end

  def test_batch_audit_ignores_empty_string_target
    write_state_record(
      "batches/batch-empty-target.json",
      { "schema_version" => 1, "batch_id" => "batch-empty-target",
        "lanes" => [{ "name" => "code", "owner" => "worker-a", "targets" => [""] }] }
    )
    # A typed event with no target and a non-matching owner must not be credited
    # to a lane whose only target is the empty string.
    seed_event(
      "batch-empty-target", "e1",
      "type" => "help_requested", "reason" => "question", "agent_id" => "someone-else"
    )

    result = run_agent_coord("batch-audit", "--batch-id", "batch-empty-target", "--json")

    assert_equal 1, result.status.exitstatus, result.stderr
    lane = JSON.parse(result.stdout).fetch("lanes").first
    assert_empty lane.fetch("targets")
    assert_equal 0, lane.fetch("event_count")
    refute lane.fetch("complete")
  end

  def test_batch_audit_ignores_events_from_a_different_repo
    write_state_record(
      "batches/batch-repo-a.json",
      { "schema_version" => 1, "batch_id" => "batch-repo-a", "repo" => "shakacode/repo-a",
        "lanes" => [{ "name" => "code", "owner" => "worker-a", "targets" => ["42"] }] }
    )
    # Same batch-id, target number, and owner but a DIFFERENT repo must not attribute.
    run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/repo-b", "--target", "42",
      "--batch-id", "batch-repo-a", "--branch", "b"
    )
    run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/repo-b", "--target", "42",
      "--batch-id", "batch-repo-a", "--branch", "b"
    )

    result = run_agent_coord("batch-audit", "--batch-id", "batch-repo-a", "--json")

    assert_equal 1, result.status.exitstatus, result.stderr
    lane = JSON.parse(result.stdout).fetch("lanes").first
    assert_equal 0, lane.fetch("event_count")
    refute lane.fetch("complete")
    assert_equal ["claim.acquired", "terminal"], lane.fetch("missing")
  end

  def test_batch_audit_completes_with_matching_repo_events
    write_state_record(
      "batches/batch-repo-a.json",
      { "schema_version" => 1, "batch_id" => "batch-repo-a", "repo" => "shakacode/repo-a",
        "lanes" => [{ "name" => "code", "owner" => "worker-a", "targets" => ["42"] }] }
    )
    run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/repo-a", "--target", "42",
      "--batch-id", "batch-repo-a", "--branch", "b"
    )
    run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/repo-a", "--target", "42",
      "--batch-id", "batch-repo-a", "--branch", "b"
    )

    result = run_agent_coord("batch-audit", "--batch-id", "batch-repo-a")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "batch-audit batch-repo-a complete"
  end

  def test_batch_audit_owner_fallback_ignores_out_of_lane_target
    write_state_record(
      "batches/batch-owner-target.json",
      { "schema_version" => 1, "batch_id" => "batch-owner-target",
        "lanes" => [{ "name" => "code", "owner" => "worker-a", "targets" => ["101"] }] }
    )
    # The unique lane owner does unrelated work on a DIFFERENT target under the same
    # batch-id/repo; that must not complete this lane (owner fallback requires the
    # event target to belong to the lane).
    run_agent_coord(
      "claim", "--agent-id", "worker-a", "--repo", "shakacode/x", "--target", "999",
      "--batch-id", "batch-owner-target", "--branch", "b"
    )
    run_agent_coord(
      "release", "--agent-id", "worker-a", "--repo", "shakacode/x", "--target", "999",
      "--batch-id", "batch-owner-target", "--branch", "b"
    )

    result = run_agent_coord("batch-audit", "--batch-id", "batch-owner-target", "--json")

    assert_equal 1, result.status.exitstatus, result.stderr
    lane = JSON.parse(result.stdout).fetch("lanes").first
    assert_equal 0, lane.fetch("event_count")
    refute lane.fetch("complete")
    assert_equal ["claim.acquired", "terminal"], lane.fetch("missing")
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

  def test_dependency_gating_accepts_canonical_and_legacy_terminal_statuses
    now = Time.now.utc
    write_batch(
      "batch-vocab-deps",
      lanes: [
        { "name" => "legacy", "owner" => "worker-legacy", "targets" => ["4201"] },
        { "name" => "canonical", "owner" => "worker-canonical", "targets" => ["4202"] },
        {
          "name" => "consumer",
          "owner" => "worker-consumer",
          "targets" => ["4203"],
          "depends_on" => ["batch-vocab-deps:legacy", "batch-vocab-deps:canonical"]
        }
      ]
    )
    write_heartbeat("worker-legacy", status: "completed", updated_at: now - 60, expires_at: now + 600)
    write_heartbeat("worker-canonical", status: "ready_gates_clean", updated_at: now - 60, expires_at: now + 600)
    write_heartbeat("worker-consumer", status: "blocked", updated_at: now - 60, expires_at: now + 600)

    status = run_agent_coord("status", "--batch-id", "batch-vocab-deps", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    lanes = JSON.parse(status.stdout).fetch("batches").first.fetch("lanes")
    consumer = lanes.find { |lane| lane.fetch("name") == "consumer" }
    assert_empty consumer.fetch("blocked_on"), "expected legacy and canonical terminal statuses to satisfy deps"
  end

  def test_dependency_gating_keeps_abandoned_lane_blocking_dependents
    now = Time.now.utc
    write_batch(
      "batch-vocab-abandoned",
      lanes: [
        { "name" => "base", "owner" => "worker-base", "targets" => ["4204"] },
        {
          "name" => "consumer",
          "owner" => "worker-consumer",
          "targets" => ["4205"],
          "depends_on" => ["batch-vocab-abandoned:base"]
        }
      ]
    )
    write_heartbeat("worker-base", status: "abandoned", updated_at: now - 60, expires_at: now + 600)
    write_heartbeat("worker-consumer", status: "blocked", updated_at: now - 60, expires_at: now + 600)

    status = run_agent_coord("status", "--batch-id", "batch-vocab-abandoned", "--json")

    assert_equal 0, status.status.exitstatus, status.stderr
    lanes = JSON.parse(status.stdout).fetch("batches").first.fetch("lanes")
    consumer = lanes.find { |lane| lane.fetch("name") == "consumer" }
    assert_equal ["batch-vocab-abandoned:base"], consumer.fetch("blocked_on")
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

  def valid_gc_lane_closed(event_id:, batch_id:, target:, at:, extra: {})
    {
      "schema_version" => 2,
      "event_id" => event_id,
      "batch_id" => batch_id,
      "type" => "lane_closed",
      "repo" => "shakacode/example",
      "target" => target,
      "terminal" => "done",
      "workspace" => "default",
      "closed_by" => { "agent_id" => "gc-worker", "machine" => "test" },
      "at" => at
    }.merge(extra)
  end

  def synthetic_family_policy_records(now)
    old = (now - (2 * 86_400)).iso8601
    {
      "claims/shakacode/example/scripted-active.json" => {
        "schema_version" => 1, "repo" => "shakacode/example", "target" => "scripted-active",
        "agent_id" => "scripted-worker", "status" => "active", "updated_at" => old,
        "expires_at" => (now + 86_400).iso8601, "synthetic" => true
      },
      "claims/shakacode/example/released.json" => {
        "schema_version" => 1, "repo" => "shakacode/example", "target" => "released",
        "agent_id" => "released-worker", "status" => "released", "updated_at" => old, "synthetic" => true
      },
      "heartbeats/scripted-worker.json" => {
        "schema_version" => 1, "agent_id" => "scripted-worker", "status" => "in_progress",
        "repo" => "shakacode/example", "target" => "scripted-active", "updated_at" => now.iso8601,
        "expires_at" => (now + 900).iso8601, "synthetic" => true
      },
      "heartbeats/dead-synthetic.json" => {
        "schema_version" => 1, "agent_id" => "dead-synthetic", "status" => "in_progress",
        "updated_at" => old, "expires_at" => (Time.iso8601(old) + 900).iso8601, "synthetic" => true
      },
      "batches/incomplete-synthetic.json" => {
        "schema_version" => 1, "batch_id" => "incomplete-synthetic", "status" => "active",
        "updated_at" => old, "synthetic" => true, "lanes" => []
      },
      "batches/completed-synthetic.json" => {
        "schema_version" => 1, "batch_id" => "completed-synthetic", "status" => "completed",
        "updated_at" => old, "completed_at" => old, "synthetic" => true, "lanes" => []
      }
    }
  end

  def write_expired_reuse_candidates(now)
    old = (now - (8 * 86_400)).iso8601
    expired = (now - 86_400).iso8601
    claim_source = "claims/shakacode/example/reused.json"
    claim_archive = "archive/#{claim_source}"
    claim_data = {
      "schema_version" => 1, "repo" => "shakacode/example", "target" => "reused",
      "agent_id" => "worker-reused", "status" => "released", "updated_at" => old
    }
    write_state_record(claim_source, claim_data)
    write_state_record(
      claim_archive,
      "schema_version" => 1, "record_family" => "archived_record", "source_path" => claim_source,
      "reason" => "terminal_claim", "synthetic" => false, "archived_at" => old,
      "delete_after" => expired, "data" => claim_data
    )

    event_source = "events/reused/lane_closed-stable.json"
    event_data = valid_gc_lane_closed(
      event_id: "lane_closed-stable", batch_id: "reused", target: "event-reused", at: old
    )
    event_entry = AgentCoord::StoredJson.new(path: event_source, data: event_data)
    planner = AgentCoord::Runner.new([])
    compact_archive = planner.send(
      :gc_compaction_archive_path, "reused", nil, "shakacode/example", "event-reused", [event_entry]
    )
    write_state_record(event_source, event_data)
    write_state_record(
      compact_archive,
      "schema_version" => 1, "record_family" => "compacted_events", "source_paths" => [event_source],
      "reason" => "terminal_target_events", "synthetic" => false, "archived_at" => old,
      "delete_after" => expired, "records" => [event_data]
    )
    [[claim_source, event_source], [claim_archive, compact_archive]]
  end

  def archived_record_for(source_path, data, delete_after)
    {
      "schema_version" => 1, "record_family" => "archived_record", "source_path" => source_path,
      "reason" => "terminal_claim", "synthetic" => false,
      "archived_at" => "2026-01-01T00:00:00Z", "delete_after" => delete_after.iso8601, "data" => data
    }
  end

  CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true)
  IDENTITY_ENV_KEYS = %w[AGENT_COORD_MACHINE_ID AGENT_COORD_SESSION_ID CODEX_THREAD_ID].freeze
  # An empty XDG config home keeps the suite off the developer's real
  # ~/.config/agent-coord/env, which would otherwise trip the split-brain guard.
  ISOLATED_CONFIG_HOME = Dir.mktmpdir("agent-coord-isolated-config")
  Minitest.after_run { FileUtils.rm_rf(ISOLATED_CONFIG_HOME) }
  COMMAND_ENV = {
    "AGENT_COORD_API_TOKEN" => nil,
    "AGENT_COORD_API_URL" => nil,
    "AGENT_COORD_BACKEND" => nil,
    "AGENT_COORD_ENV_FILE" => nil,
    "AGENT_COORD_LOCAL" => nil,
    "AGENT_COORD_MACHINE_ID" => nil,
    "AGENT_COORD_SESSION_ID" => nil,
    "AGENT_COORD_STATE_ROOT" => nil,
    "AGENT_COORD_STATUS_STATE_ROOT" => nil,
    "CODEX_THREAD_ID" => nil,
    "XDG_CONFIG_HOME" => ISOLATED_CONFIG_HOME
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

  class ObservedDirectoryFsyncLocalStore < AgentCoord::LocalStore
    attr_reader :fsynced_directories, :target_existed_during_fsync

    def initialize(root)
      super
      @fsynced_directories = []
    end

    private

    def fsync_parent_directory(file)
      @target_existed_during_fsync = File.exist?(file)
      super
    end

    def fsync_directory(directory)
      @fsynced_directories << directory
      super
    end
  end

  class UnsupportedDirectoryFsyncLocalStore < AgentCoord::LocalStore
    private

    def fsync_directory(_directory)
      raise Errno::EINVAL
    end
  end

  class FailingDirectoryFsyncLocalStore < AgentCoord::LocalStore
    private

    def fsync_directory(_directory)
      raise Errno::EACCES
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
          AgentCoordTest.wait_for_condition!(@condition, @mutex, "batch closeout participants") do
            @waiting == 2
          end
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
          AgentCoordTest.wait_for_condition!(@condition, @mutex, "event reservation participants") do
            @waiting == 2
          end
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
        if @waiting == 2
          @condition.broadcast
        else
          AgentCoordTest.wait_for_condition!(@condition, @mutex, "claim release participants") do
            @waiting == 2
          end
        end
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

  def thread_values!(threads, label)
    Timeout.timeout(THREAD_TIMEOUT) { threads.map(&:value) }
  rescue Timeout::Error
    threads.each(&:kill)
    flunk "timed out waiting for #{label}"
  ensure
    threads.each { |thread| thread.join(0.1) }
  end

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

  def read_heartbeat(agent_id)
    JSON.parse(File.read(File.join(@state_root, "heartbeats", "#{agent_id}.json")))
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

  def write_state_record(path, payload)
    full_path = File.join(@state_root, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, "#{JSON.pretty_generate(payload)}\n")
  end

  def event_records(batch_id)
    Dir.glob(File.join(@state_root, "events", batch_id, "*.json")).map { |path| JSON.parse(File.read(path)) }
  end

  def seed_event(batch_id, event_id, overrides = {})
    write_state_record(
      "events/#{batch_id}/#{event_id}.json",
      { "schema_version" => 1, "event_id" => event_id, "batch_id" => batch_id, "at" => "2026-07-22T00:00:00Z" }
        .merge(overrides)
    )
  end

  def seed_batch_audit_terminal_case(batch_id, target)
    repo = "shakacode/example"
    lane = "code"
    owner = "worker-a"
    write_state_record(
      "batches/#{batch_id}.json",
      "schema_version" => 1,
      "batch_id" => batch_id,
      "repo" => repo,
      "lanes" => [{ "name" => lane, "owner" => owner, "targets" => [target] }]
    )
    seed_event(
      batch_id,
      "claim",
      "type" => "claim.acquired",
      "lane" => lane,
      "agent_id" => owner,
      "repo" => repo,
      "target" => target,
      "status" => "active"
    )
    seed_event(
      batch_id,
      "release",
      "type" => "claim.released",
      "lane" => lane,
      "agent_id" => owner,
      "repo" => repo,
      "target" => target,
      "status" => "released"
    )
    [valid_batch_audit_terminal_event(batch_id, lane, owner, repo, target)]
  end

  def ordinary_lifecycle_scalar_cases
    {
      "claim-event-id-integer" => ->(events, _target) { events.fetch("claim")["event_id"] = 123 },
      "claim-target-integer" => ->(events, target) { events.fetch("claim")["target"] = Integer(target) },
      "release-event-id-array" => ->(events, _target) { events.fetch("release")["event_id"] = ["release"] },
      "release-target-integer" => ->(events, target) { events.fetch("release")["target"] = Integer(target) },
      "phase-status-integer" => ->(events, _target) { events.fetch("phase")["status"] = 1 },
      "phase-values-integers" => lambda do |events, _target|
        events.fetch("phase").merge!("old_phase" => 1, "new_phase" => 2, "phase" => 2)
      end,
      "phase-event-id-object" => lambda do |events, _target|
        events.fetch("phase")["event_id"] = { "id" => "phase" }
      end,
      "phase-target-integer" => ->(events, target) { events.fetch("phase")["target"] = Integer(target) },
      "claim-event-id-whitespace" => ->(events, _target) { events.fetch("claim")["event_id"] = " \t " }
    }
  end

  def ordinary_lifecycle_control_cases
    {
      "historical-phase-fields" => ->(_events, _target) {},
      "published-phase-fields" => lambda do |events, _target|
        phase = events.fetch("phase")
        phase["previous_phase"] = phase.delete("old_phase")
        phase.delete("new_phase")
        phase.delete("status")
        events.fetch("claim").delete("status")
      end,
      "phase-optional" => ->(events, _target) { events.delete("phase") },
      "valid-duplicates" => lambda do |events, _target|
        events["claim-copy"] = events.fetch("claim").merge("event_id" => "claim-copy")
        events["release-copy"] = events.fetch("release").merge("event_id" => "release-copy")
      end
    }
  end

  def ordinary_lifecycle_audit_outcome(name, batch_id, target_number, mutate)
    target = target_number.to_s
    events = seed_batch_audit_ordinary_case(batch_id, target)
    mutate.call(events, target)
    events.each do |filename, event|
      write_state_record("events/#{batch_id}/#{filename}.json", event)
    end

    result = run_agent_coord("batch-audit", "--batch-id", batch_id, "--json")
    audit = JSON.parse(result.stdout)
    lane = audit.fetch("lanes").fetch(0)
    {
      name: name,
      exit: result.status.exitstatus,
      verdict: audit.fetch("verdict"),
      complete: lane.fetch("complete"),
      missing: lane.fetch("missing")
    }
  end

  def seed_batch_audit_ordinary_case(batch_id, target)
    repo = "shakacode/example"
    lane = "code"
    owner = "worker-a"
    base = {
      "schema_version" => 1,
      "batch_id" => batch_id,
      "lane" => lane,
      "agent_id" => owner,
      "repo" => repo,
      "target" => target,
      "at" => "2026-07-22T00:00:00Z"
    }
    write_state_record(
      "batches/#{batch_id}.json",
      "schema_version" => 1,
      "batch_id" => batch_id,
      "repo" => repo,
      "lanes" => [{ "name" => lane, "owner" => owner, "targets" => [target] }]
    )
    {
      "claim" => base.merge(
        "event_id" => "claim", "type" => "claim.acquired", "status" => "active"
      ),
      "phase" => base.merge(
        "event_id" => "phase",
        "type" => "phase.changed",
        "status" => "in_progress",
        "old_phase" => "implementing",
        "new_phase" => "validating",
        "phase" => "validating"
      ),
      "release" => base.merge(
        "event_id" => "release", "type" => "claim.released", "status" => "released"
      )
    }
  end

  def valid_batch_audit_terminal_event(batch_id, lane, owner, repo, target)
    {
      "schema_version" => 2,
      "event_id" => "closed",
      "batch_id" => batch_id,
      "lane" => lane,
      "type" => "lane_closed",
      "agent_id" => owner,
      "repo" => repo,
      "target" => target,
      "branch" => "feature/strict-terminal-audit",
      "terminal" => "done",
      "pr_url" => "https://example.test/pull/1",
      "pr_state" => "merged",
      "evidence_url" => "https://example.test/evidence/1",
      "workspace" => "default",
      "closed_by" => { "agent_id" => owner, "machine" => "test" },
      "at" => "2026-07-22T00:00:00Z"
    }
  end

  def write_batch_audit_terminals(batch_id, terminals)
    terminals.each_with_index do |terminal, index|
      write_state_record("events/#{batch_id}/closed-#{index}.json", terminal)
    end
  end

  def invalid_terminal_audit_outcomes(families)
    case_index = 0
    families.flat_map do |family, variants|
      variants.map do |variant, mutate|
        outcome = terminal_audit_outcome(
          "#{family}/#{variant}", "batch-audit-strict-terminal-#{case_index}", 8100 + case_index, mutate
        )
        case_index += 1
        outcome
      end
    end
  end

  def terminal_audit_control_outcomes
    batch_audit_terminal_controls.each_with_index.map do |(name, mutate), index|
      terminal_audit_outcome(name, "batch-audit-strict-terminal-control-#{index}", 8200 + index, mutate)
    end
  end

  def terminal_audit_outcome(name, batch_id, target_number, mutate)
    target = target_number.to_s
    terminals = seed_batch_audit_terminal_case(batch_id, target)
    mutate.call(terminals, batch_id, target)
    write_batch_audit_terminals(batch_id, terminals)
    result = run_agent_coord("batch-audit", "--batch-id", batch_id, "--json")
    audit = JSON.parse(result.stdout)
    lane = audit.fetch("lanes").fetch(0)
    {
      name: name,
      exit: result.status.exitstatus,
      verdict: audit.fetch("verdict"),
      complete: lane.fetch("complete"),
      missing: lane.fetch("missing")
    }
  end

  # Declarative public-CLI regression matrix: keeping the mutations inline makes
  # the 12 contract families and their exact boundary values reviewable together.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def batch_audit_terminal_false_complete_families
    {
      "unknown-and-non-facts" => {
        "exact-unknown" => ->(events, _batch_id, _target) { events.fetch(0)["workspace"] = "UNKNOWN" },
        "nested-unknown" => lambda { |events, _batch_id, _target|
          events.fetch(0).fetch("closed_by")["machine"] = " uNkNoWn "
        },
        "blank" => ->(events, _batch_id, _target) { events.fetch(0)["branch"] = "" },
        "whitespace" => ->(events, _batch_id, _target) { events.fetch(0)["pr_state"] = " \t " }
      },
      "wrong-scalar-types" => {
        "schema-version-string" => ->(events, _batch_id, _target) { events.fetch(0)["schema_version"] = "2" },
        "event-id-integer" => ->(events, _batch_id, _target) { events.fetch(0)["event_id"] = 123 },
        "workspace-array" => ->(events, _batch_id, _target) { events.fetch(0)["workspace"] = ["default"] }
      },
      "invalid-evidence-uri" => {
        "javascript" => lambda { |events, _batch_id, _target|
          events.fetch(0)["evidence_url"] = "javascript:alert(1)"
        }
      },
      "whitespace-evidence-uri" => {
        "embedded-space" => lambda { |events, _batch_id, _target|
          events.fetch(0)["evidence_url"] = "https://example.test/evidence /1"
        }
      },
      "integer-evidence-value" => {
        "integer" => ->(events, _batch_id, _target) { events.fetch(0)["evidence_url"] = 123 }
      },
      "missing-closed-by" => {
        "missing" => ->(events, _batch_id, _target) { events.fetch(0).delete("closed_by") }
      },
      "invalid-closed-by" => {
        "extra-field" => lambda { |events, _batch_id, _target|
          events.fetch(0).fetch("closed_by")["unexpected"] = "not-allowed"
        },
        "empty-machine" => lambda { |events, _batch_id, _target|
          events.fetch(0).fetch("closed_by")["machine"] = ""
        }
      },
      "scalar-closed-by" => {
        "string" => ->(events, _batch_id, _target) { events.fetch(0)["closed_by"] = "worker-a" }
      },
      "impossible-calendar" => {
        "february-30" => ->(events, _batch_id, _target) { events.fetch(0)["at"] = "2026-02-30T00:00:00Z" },
        "non-leap-february-29" => lambda { |events, _batch_id, _target|
          events.fetch(0)["at"] = "2026-02-29T00:00:00Z"
        }
      },
      "invalid-time-range" => {
        "hour-24" => ->(events, _batch_id, _target) { events.fetch(0)["at"] = "2026-01-01T24:00:00Z" },
        "minute-60" => ->(events, _batch_id, _target) { events.fetch(0)["at"] = "2026-01-01T23:60:00Z" },
        "second-61" => ->(events, _batch_id, _target) { events.fetch(0)["at"] = "2026-01-01T23:59:61Z" }
      },
      "invalid-time-offset" => {
        "timezone-less" => ->(events, _batch_id, _target) { events.fetch(0)["at"] = "2026-01-01T00:00:00" },
        "offset-hour-24" => lambda { |events, _batch_id, _target|
          events.fetch(0)["at"] = "2026-01-01T12:00:00+24:00"
        },
        "offset-minute-60" => lambda { |events, _batch_id, _target|
          events.fetch(0)["at"] = "2026-01-01T12:00:00+09:60"
        }
      },
      "conflicting-duplicate-facts" => {
        "terminal-state" => lambda { |events, _batch_id, _target|
          conflict = events.fetch(0).merge(
            "event_id" => "closed-conflict",
            "terminal" => "abandoned",
            "at" => "2026-07-22T00:00:01Z"
          )
          events << conflict
        }
      }
    }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def batch_audit_terminal_controls
    {
      "valid-published-shape" => ->(_events, _batch_id, _target) {},
      "historical-proleptic-gregorian" => lambda { |events, _batch_id, _target|
        events.fetch(0)["at"] = "1582-10-10T00:00:00Z"
      },
      "identical-non-conflicting-duplicates" => lambda { |events, _batch_id, _target|
        duplicate = JSON.parse(JSON.generate(events.fetch(0)))
        duplicate["event_id"] = "closed-replay"
        duplicate["at"] = "2026-07-22T00:00:01Z"
        events << duplicate
      },
      "real-published-fixture" => lambda { |events, batch_id, target|
        fixture = JSON.parse(File.read(File.join(ROOT, "contracts/fixtures/v2/lane_closed.json")))
        fixture["batch_id"] = batch_id
        fixture["lane"] = "code"
        fixture["repo"] = "shakacode/example"
        fixture["target"] = target
        fixture.fetch("closed_by")["agent_id"] = "worker-a"
        events.replace([fixture])
      }
    }
  end

  def events_of_type(batch_id, type)
    event_records(batch_id).select { |event| event["type"] == type }
  end

  def event_of_type(batch_id, type)
    matches = events_of_type(batch_id, type)
    assert_equal 1, matches.length, "expected exactly one #{type} event in #{batch_id}"
    matches.first
  end

  def run_agent_coord(*, state_root: @state_root, stdin_data: nil, env: {})
    merged_env = {}
    merged_env["AGENT_COORD_STATE_ROOT"] = state_root if state_root
    run_command(merged_env.merge(env), "ruby", BIN, *, stdin_data: stdin_data)
  end

  def with_identity_env(values)
    saved = IDENTITY_ENV_KEYS.to_h { |key| [key, ENV.fetch(key, nil)] }
    IDENTITY_ENV_KEYS.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def run_command(*args, stdin_data: nil)
    env = args.first.is_a?(Hash) ? args.shift : {}
    stdout, stderr, status = Open3.capture3(COMMAND_ENV.merge(env), *args, stdin_data: stdin_data)
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
      "type" => "claim.released",
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
    refute event.key?("status_raw"), "expected the claim-status snapshot to bypass status coercion"
  end

  def assert_handoff_status_event(status_event, event_id)
    assert_equal event_id, status_event.fetch("event_id")
    assert_equal "claim.released", status_event.fetch("type")
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

  # archived accepts true/false to shape the `archived` flag, or a symbol to
  # simulate degraded backend metadata: :unreadable (gh api fails), :missing_key
  # (object without an `archived` field), or :not_object (valid JSON that is not
  # a Hash, e.g. null).
  def write_fake_gh(fake_bin, archived: false)
    api_repos_body =
      case archived
      when :unreadable
        %(warn "Not Found"; exit 1)
      when :missing_key
        %(puts JSON.generate("full_name" => "shakacode/agent-coordination-state"); exit 0)
      when :not_object
        %(puts JSON.generate(nil); exit 0)
      else
        %(puts JSON.generate("archived" => #{archived}); exit 0)
      end

    File.write(
      File.join(fake_bin, "gh"),
      <<~RUBY
        #!/usr/bin/env ruby
        require "json"
        command = ARGV.join(" ")
        case command
        when "auth status"
          exit 0
        when /^repo view /
          exit 0
        when %r{^api repos/[^/]+/[^/]+$}
          #{api_repos_body}
        when ->(value) { value.include?("git/trees/missing-ref") }
          warn "Not Found"
          exit 1
        else
          warn "unexpected gh command: \#{command}"
          exit 1
        end
      RUBY
    )
    FileUtils.chmod(0o755, File.join(fake_bin, "gh"))
  end
end
