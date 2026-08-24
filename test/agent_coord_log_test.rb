# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

# `agent-coord log` renders the per-work-item custody trail already carried by
# the event store (issue #129). These tests pin the operator contract: which
# machine and host touched a work item, whether it moved, and when it was last
# worked on -- with no state inference beyond ordering events by timestamp.
class AgentCoordLogTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "agent-coord")
  CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true)
  LOG_TSV_FIELD_COUNT = 11
  # Keeps the suite off the developer's real ~/.config/agent-coord/env, which
  # would otherwise trip the split-brain advisory and pollute stderr assertions.
  ISOLATED_CONFIG_HOME = Dir.mktmpdir("agent-coord-log-config")
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

  def setup
    @state_root = Dir.mktmpdir("agent-coord-log-test")
  end

  def teardown
    FileUtils.remove_entry(@state_root)
  end

  # --- work-item trace -------------------------------------------------------

  def test_log_traces_one_work_item_in_chronological_order
    write_trace

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    types = result.stdout.lines.map { |line| line.split(/\s+/)[4] }

    assert_equal %w[claim.acquired phase.changed claim.released claim.acquired lane_closed], types
  end

  def test_log_reports_machine_and_host_for_each_event
    write_trace

    line = run_log("shakacode/example#104").stdout.lines.first.split(/\s+/)

    assert_equal "2026-08-03T02:40:16Z", line[0]
    assert_equal "m5", line[1]
    assert_equal "codex", line[2]
    assert_equal "shakacode/example#104", line[3]
  end

  def test_log_shows_the_move_between_machines_and_hosts
    write_trace

    columns = run_log("shakacode/example#104").stdout.lines.map { |line| line.split(/\s+/)[1, 2] }

    assert_equal [%w[m5 codex], %w[m5 codex], %w[m5 codex], %w[m1 claude], %w[m1 claude]], columns
  end

  def test_log_renders_phase_transitions_and_handoff_destinations_as_detail
    write_trace

    stdout = run_log("shakacode/example#104").stdout

    assert_includes stdout, "addressing_review -> waiting_on_checks_or_review"
    assert_includes stdout, "-> maintainer"
  end

  def test_log_excludes_other_work_items
    write_trace

    stdout = run_log("shakacode/example#104").stdout

    refute_includes stdout, "shakacode/other#7"
  end

  def test_log_reports_no_events_without_failing
    write_trace

    result = run_log("shakacode/example#999")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "no events"
  end

  # The live event store records shakacode/hichee under two different casings.
  # Exact matching would split one repo's history into two partial answers.
  def test_log_matches_the_work_item_regardless_of_repo_casing
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "ShakaCode/hichee", "target" => "9765",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    write_event("b1", "e2", "type" => "lane_closed", "repo" => "shakacode/hichee", "target" => "9765",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-02T00:00:00Z")

    %w[ShakaCode/hichee#9765 shakacode/hichee#9765 SHAKACODE/HICHEE#9765].each do |query|
      assert_equal 2, run_log(query).stdout.lines.length, "expected #{query} to find both casings"
    end
  end

  def test_log_matches_machine_and_host_filters_regardless_of_casing
    write_trace

    assert_equal 2, run_log("--machine", "M1").stdout.lines.length
    assert_equal 2, run_log("--host", "Claude").stdout.lines.length
  end

  # A work item can hold a claim while having no event trail -- claims predating
  # auto-emit were overwritten in place. Reporting a bare "no events" there would
  # hide live custody, so the claim record is surfaced instead.
  def test_log_falls_back_to_the_claim_record_when_a_work_item_has_no_events
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2026-08-01T03:13:03Z", "phase" => "implementation")

    stdout = run_log("shakacode/example#10112").stdout

    assert_includes stdout, "no events"
    assert_includes stdout, "claim"
    assert_includes stdout, "active"
    assert_includes stdout, "m5"
    assert_includes stdout, "2026-08-01T03:13:03Z"
  end

  def test_log_reports_no_claim_when_a_work_item_is_entirely_unknown
    write_trace

    stdout = run_log("shakacode/example#999").stdout

    assert_includes stdout, "no events"
    refute_includes stdout, "claim "
  end

  # --- honesty about missing data --------------------------------------------

  def test_log_renders_unknown_machine_as_a_placeholder_rather_than_guessing
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                            "host" => "codex", "at" => "2026-08-01T00:00:00Z")

    line = run_log("shakacode/example#5").stdout.lines.first.split(/\s+/)

    assert_equal "?", line[1]
  end

  def test_log_renders_unknown_host_as_a_placeholder_rather_than_guessing
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m1", "at" => "2026-08-01T00:00:00Z")

    line = run_log("shakacode/example#5").stdout.lines.first.split(/\s+/)

    assert_equal "?", line[2]
  end

  # --- host normalization ----------------------------------------------------

  def test_log_normalizes_the_sprawled_host_vocabulary_into_two_families
    {
      "codex" => "codex", "codex-subagent" => "codex", "codex-desktop" => "codex",
      "codex-collaboration@its" => "codex", "codex-worktree-thread" => "codex",
      "claude-code" => "claude", "claude" => "claude"
    }.each_with_index do |(raw, family), index|
      write_event("b1", "e#{index}", "type" => "claim.acquired", "repo" => "shakacode/example",
                                     "target" => String(index), "host" => raw,
                                     "at" => "2026-08-01T00:0#{index}:00Z")

      line = run_log("shakacode/example##{index}").stdout.lines.first.split(/\s+/)

      assert_equal family, line[2], "expected host #{raw.inspect} to normalize to #{family}"
    end
  end

  def test_log_preserves_the_raw_host_value_in_tsv_output
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                            "host" => "codex-collaboration@its", "at" => "2026-08-01T00:00:00Z")

    fields = run_log("shakacode/example#5", "--format", "tsv").stdout.lines.first.chomp.split("\t")

    assert_equal "codex", fields[2]
    assert_includes fields, "codex-collaboration@its"
  end

  # --- filters ---------------------------------------------------------------

  def test_log_filters_synthetic_records_by_default_and_includes_them_on_request
    write_trace
    write_event("sim", "s1", "type" => "claim.acquired", "repo" => "sim/race", "target" => "task_two",
                             "machine_id" => "m5", "host" => "scripted-sim", "synthetic" => true,
                             "at" => "2026-08-03T05:00:00Z")

    refute_includes run_log.stdout, "sim/race#task_two"
    assert_includes run_log("--include-synthetic").stdout, "sim/race#task_two"
  end

  def test_log_filters_by_machine
    write_trace

    stdout = run_log("--machine", "m1").stdout

    assert_equal 2, stdout.lines.length
    stdout.lines.each { |line| assert_equal "m1", line.split(/\s+/)[1] }
  end

  def test_log_filters_by_host_family
    write_trace

    stdout = run_log("--host", "claude").stdout

    assert_equal 2, stdout.lines.length
    stdout.lines.each { |line| assert_equal "claude", line.split(/\s+/)[2] }
  end

  def test_log_filters_by_event_type
    write_trace

    stdout = run_log("--type", "claim.acquired").stdout

    assert_equal 3, stdout.lines.length
    stdout.lines.each { |line| assert_equal "claim.acquired", line.split(/\s+/)[4] }
  end

  def test_log_filters_by_relative_since_window
    write_trace

    stdout = run_log("--since", "2026-08-03T03:00:00Z").stdout

    assert_equal 2, stdout.lines.length
    assert_includes stdout, "lane_closed"
    refute_includes stdout, "claim.released"
  end

  def test_log_rejects_an_unparseable_since_value
    write_trace

    result = run_log("--since", "yesterday")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "--since"
  end

  def test_log_limit_keeps_the_most_recent_events
    write_trace

    stdout = run_log("shakacode/example#104", "--limit", "2").stdout

    assert_equal 2, stdout.lines.length
    assert_includes stdout.lines.last, "lane_closed"
  end

  # --- output shapes ---------------------------------------------------------

  def test_log_emits_structured_json_on_request
    write_trace

    payload = JSON.parse(run_log("shakacode/example#104", "--json").stdout)
    first = payload.fetch("events").first

    assert_equal 5, payload.fetch("events").length
    assert_equal "shakacode/example#104", first.fetch("work_item")
    assert_equal "m5", first.fetch("machine")
    assert_equal "codex", first.fetch("host")
    assert_equal "claim.acquired", first.fetch("type")
  end

  def test_log_sync_writes_a_greppable_tsv_under_the_state_root
    write_trace

    result = run_log("--sync")
    log_path = File.join(@state_root, "log.tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_path_exists log_path
    lines = File.readlines(log_path)

    assert_equal 6, lines.length
    assert(lines.any? { |line| line.include?("shakacode/example#104") && line.include?("lane_closed") })
  end

  def test_log_sync_is_idempotent_and_appends_only_unseen_events
    write_trace
    run_log("--sync")
    first_pass = File.readlines(File.join(@state_root, "log.tsv"))

    run_log("--sync")
    second_pass = File.readlines(File.join(@state_root, "log.tsv"))

    assert_equal first_pass, second_pass

    write_event("b2", "e9", "type" => "merged", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m1", "host" => "claude-code", "at" => "2026-08-04T00:00:00Z")
    run_log("--sync")
    third_pass = File.readlines(File.join(@state_root, "log.tsv"))

    assert_equal first_pass.length + 1, third_pass.length
    assert_includes third_pass.last, "merged"
  end

  # Under a non-UTF-8 locale the appended line reads back tagged with the locale
  # encoding, so a row carrying any non-ASCII character (an em dash in a merge
  # note, say) failed the dedup lookup and re-appended on every sync, growing the
  # file without bound. The log always reads and writes UTF-8 regardless of locale.
  def test_log_sync_dedupes_non_ascii_rows_under_an_ascii_locale
    write_event("b1", "e1", "type" => "lane", "repo" => "shakacode/example", "target" => "4711",
                            "machine_id" => "m5", "host" => "codex",
                            "message" => "PR 4711 merged \u2014 verified via GitHub",
                            "at" => "2026-07-17T22:52:29Z")
    ascii_locale = { "LC_ALL" => "C", "LANG" => "C" }

    3.times { run_log("--sync", env: ascii_locale) }
    lines = File.readlines(File.join(@state_root, "log.tsv"), encoding: "UTF-8")

    assert_equal 1, lines.length, "expected the non-ASCII row to be written exactly once"
    assert_includes lines.first, "\u2014"
  end

  def test_log_sync_retains_history_after_events_are_pruned
    write_trace
    run_log("--sync")
    FileUtils.rm_rf(File.join(@state_root, "events"))

    run_log("--sync")

    assert_includes File.read(File.join(@state_root, "log.tsv")), "shakacode/example#104"
  end

  # --- review findings (PR #131) ---------------------------------------------

  # `log` was registered as a backend command but not a status-read command, so
  # it silently read the default local root instead of the configured status root
  # and skipped the split-brain advisory it is supposed to keep.
  def test_log_reads_the_configured_status_state_root
    write_trace
    # An empty XDG state home makes the implicit local root definitively empty, so
    # finding the trail proves the configured status root was the one consulted.
    empty_state_home = Dir.mktmpdir("agent-coord-log-state-home")

    result = run_command(
      COMMAND_ENV.merge("AGENT_COORD_STATUS_STATE_ROOT" => @state_root, "XDG_STATE_HOME" => empty_state_home),
      "ruby", BIN, "log", "shakacode/example#104"
    )

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal 5, result.stdout.lines.length
  ensure
    FileUtils.remove_entry(empty_state_home)
  end

  # "?" (0x3F) sorts after every digit, so an undated legacy event landed last and
  # became the "where is it now" line, which is the one thing the trail must not
  # get wrong. Undated events are older than anything stamped, so they sort first.
  def test_log_orders_undated_events_before_dated_ones
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    write_event("b1", "e2", "type" => "lane_closed", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex", "terminal" => "done",
                            "at" => "2026-08-02T00:00:00Z")
    write_event("b1", "e0", "type" => "phase", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex")

    lines = run_log("shakacode/example#5").stdout.lines

    assert_match(/\A\?/, lines.first, "undated event should sort first, not last")
    assert_includes lines.last, "lane_closed"
  end

  def test_log_since_excludes_undated_events
    write_event("b1", "e0", "type" => "phase", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex")

    stdout = run_log("--since", "2026-01-01T00:00:00Z").stdout

    assert_includes stdout, "no events"
  end

  # Lexical comparison does not reflect chronological order once a timestamp
  # carries an offset: 2026-08-03T05:30:00+05:00 precedes 2026-08-03T01:00:00Z.
  def test_log_orders_offset_timestamps_chronologically
    write_event("b1", "later", "type" => "lane_closed", "repo" => "shakacode/example", "target" => "5",
                               "machine_id" => "m5", "host" => "codex", "at" => "2026-08-03T01:00:00Z")
    write_event("b1", "earlier", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                                 "machine_id" => "m5", "host" => "codex", "at" => "2026-08-03T05:30:00+05:00")

    types = run_log("shakacode/example#5").stdout.lines.map { |line| line.split(/\s+/)[4] }

    assert_equal %w[claim.acquired lane_closed], types
  end

  def test_log_rejects_a_negative_limit
    write_trace

    result = run_log("--limit", "-1")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "--limit"
    refute_includes result.stderr, "negative array size"
  end

  # --limit truncates before the mirror is written, so a repeated
  # `log --limit 5 --sync` would permanently lose everything outside each
  # observation's most-recent slice once gc pruned the events behind it.
  def test_log_rejects_limit_combined_with_sync
    write_trace

    result = run_log("--sync", "--limit", "2")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "--limit"
    assert_includes result.stderr, "--sync"
  end

  def test_log_tsv_scrubs_control_characters_from_every_field
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex",
                            "agent_id" => "worker\tinjected", "batch_id" => "batch\nsplit",
                            "at" => "2026-08-01T00:00:00Z")

    lines = run_log("shakacode/example#5", "--format", "tsv").stdout.lines

    assert_equal 1, lines.length, "an embedded newline must not split the row"
    assert_equal LOG_TSV_FIELD_COUNT, lines.first.chomp.split("\t").length
  end

  # tsv is a data stream, so a human note must not be written into it -- but the
  # claim fallback must still reach the operator rather than vanishing.
  def test_log_tsv_reports_an_empty_result_on_stderr
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2026-08-01T03:13:03Z")

    result = run_log("shakacode/example#10112", "--format", "tsv")

    assert_empty result.stdout
    assert_includes result.stderr, "no events"
    assert_includes result.stderr, "claim active"
  end

  # The claim is not checked against --since/--machine/--host/--type, so surfacing
  # it after a filter emptied the trail would answer a question nobody asked.
  def test_log_does_not_fall_back_to_the_claim_when_a_filter_emptied_the_trail
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "10112",
                            "machine_id" => "m5", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2026-08-01T03:13:03Z")

    stdout = run_log("shakacode/example#10112", "--type", "error").stdout

    assert_includes stdout, "no events"
    refute_includes stdout, "claim active"
  end

  # An explicitly requested backend must not be silently replaced by the local
  # status root, or the trail answers for a different backend than the one asked
  # for, with nothing in the output saying so (PR #131 review round 2).
  def test_log_preserves_an_explicit_backend_selection
    write_trace

    result = run_command(
      COMMAND_ENV.merge("AGENT_COORD_STATUS_STATE_ROOT" => @state_root),
      "ruby", BIN, "log", "--backend", "shakacode/does-not-exist"
    )

    refute_includes result.stdout, "shakacode/example#104",
                    "an explicit --backend must not fall back to the local status root"
  end

  # OptionParser permits options before positionals, so `log --json REPO#1` is a
  # conventional invocation; shifting the positional before parsing rejected it.
  def test_log_accepts_options_before_the_work_item
    write_trace

    payload = JSON.parse(run_log("--json", "shakacode/example#104").stdout)

    assert_equal 5, payload.fetch("events").length
  end

  # The mirror is a complete durable copy, not a filtered view. A narrow sync
  # followed by a broader one would append the older events after the newer ones,
  # so the file's last line would no longer be the current state.
  def test_log_sync_rejects_trail_filters
    write_trace

    [["--since", "1d"], ["--machine", "m5"], ["--host", "codex"],
     ["--type", "claim.acquired"], ["--include-synthetic"]].each do |filter|
      result = run_log("--sync", *filter)

      assert_equal 1, result.status.exitstatus, "expected --sync #{filter.first} to be rejected"
      assert_includes result.stderr, "--sync"
    end
  end

  def test_log_sync_rejects_a_work_item_scope
    write_trace

    result = run_log("shakacode/example#104", "--sync")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "--sync"
  end

  # The tsv renderer was hardened but the default text renderer was not, so an
  # embedded newline still split one event across two printed lines.
  def test_log_text_output_scrubs_control_characters_from_every_column
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex",
                            "agent_id" => "worker\ninjected", "batch_id" => "batch\tsplit",
                            "at" => "2026-08-01T00:00:00Z")

    stdout = run_log("shakacode/example#5").stdout

    assert_equal 1, stdout.lines.length, "an embedded newline must not split the printed event"
    assert_includes stdout, "worker injected"
  end

  # Two writers (a cron and an operator, say) would each read the file before
  # either appended, and both would then write the same rows. Asserting on a race
  # would only pass by luck, so this holds the lock and checks that sync waits.
  def test_log_sync_waits_for_an_exclusive_lock_on_the_mirror
    write_trace
    path = File.join(@state_root, "log.tsv")
    FileUtils.touch(path)
    File.open(path, File::RDWR) do |holder|
      holder.flock(File::LOCK_EX)
      pid = spawn(COMMAND_ENV.merge("AGENT_COORD_STATE_ROOT" => @state_root),
                  "ruby", BIN, "log", "--sync", out: File::NULL, err: File::NULL)

      assert_nil wait_briefly(pid), "expected --sync to wait for the exclusive lock, not write through it"

      holder.flock(File::LOCK_UN)
      Process.waitpid(pid)
    end

    assert_equal 6, File.readlines(path, encoding: "UTF-8").length
  end

  # --- review findings (PR #131, round 4) ------------------------------------

  # log_row derives "phase" for events, falling back to status; reusing it for a
  # claim printed a claim whose status is active as "phase active".
  def test_log_claim_note_does_not_relabel_claim_status_as_phase
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2026-08-01T03:13:03Z")

    stdout = run_log("shakacode/example#10112").stdout

    assert_includes stdout, "claim active"
    refute_includes stdout, "phase active"
    assert_includes stdout, "phase -"
  end

  def test_log_claim_note_reports_a_real_phase_when_the_claim_has_one
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "phase" => "implementing", "updated_at" => "2026-08-01T03:13:03Z")

    assert_includes run_log("shakacode/example#10112").stdout, "phase implementing"
  end

  def test_log_sync_reports_json_when_json_is_requested
    write_trace

    payload = JSON.parse(run_log("--sync", "--json").stdout)

    assert_equal 6, payload.fetch("synced")
    assert payload.fetch("path").end_with?("log.tsv")
  end

  # A later sync can still discover an older event -- a concurrent writer, or a
  # backfill -- and appending it blindly would put it after newer rows, so the
  # mirror's last line would stop being the current state.
  def test_log_sync_keeps_the_mirror_in_timestamp_order
    write_event("b1", "e2", "type" => "lane_closed", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex", "terminal" => "done",
                            "at" => "2026-08-02T00:00:00Z")
    run_log("--sync")
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    run_log("--sync")

    lines = File.readlines(File.join(@state_root, "log.tsv"), encoding: "UTF-8")

    assert_equal 2, lines.length
    assert_includes lines.first, "2026-08-01T00:00:00Z"
    assert_includes lines.last, "2026-08-02T00:00:00Z"
  end

  # add_target_options already registers --host for every command; registering it
  # again for log collided with that definition. The log help block still
  # describes what --host means here, which is a separate line from the registry.
  def test_log_registers_host_exactly_once
    result = run_command(COMMAND_ENV, "ruby", BIN, "log", "--help")

    assert_equal 1, result.stdout.scan('--host HOST').length, "--host must not be registered twice"
  end

  # --- read-only contract ----------------------------------------------------

  def test_log_does_not_mutate_coordination_state
    write_trace
    before = state_fingerprint

    run_log
    run_log("shakacode/example#104", "--json")

    assert_equal before, state_fingerprint
  end

  def test_help_lists_the_log_command
    result = run_command(COMMAND_ENV, "ruby", BIN, "--help")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "log"
  end

  private

  # A realistic custody trail: opened on m5 under codex, handed to a maintainer,
  # then picked back up on m1 under claude and closed. Exercises the move.
  def write_trace
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m5", "host" => "codex", "agent_id" => "acd-worker",
                            "phase" => "addressing_review", "at" => "2026-08-03T02:40:16Z")
    write_event("b1", "e2", "type" => "phase.changed", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m5", "host" => "codex", "agent_id" => "acd-worker",
                            "old_phase" => "addressing_review", "phase" => "waiting_on_checks_or_review",
                            "at" => "2026-08-03T02:45:53Z")
    write_event("b1", "e3", "type" => "claim.released", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m5", "host" => "codex", "agent_id" => "acd-worker",
                            "handoff_to" => "maintainer", "at" => "2026-08-03T02:56:53Z")
    write_event("b1", "e4", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m1", "host" => "claude-code", "agent_id" => "acd-finisher",
                            "phase" => "final_merge", "at" => "2026-08-03T03:35:49Z")
    write_event("b1", "e5", "type" => "lane_closed", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m1", "host" => "claude-code", "agent_id" => "acd-finisher",
                            "terminal" => "done", "at" => "2026-08-03T04:00:08Z")
    write_event("b1", "e6", "type" => "claim.acquired", "repo" => "shakacode/other", "target" => "7",
                            "machine_id" => "m5", "host" => "codex", "agent_id" => "other-worker",
                            "at" => "2026-08-03T02:41:00Z")
  end

  # Poll briefly for the child to exit; nil means it is still blocked.
  def wait_briefly(pid, attempts: 20)
    attempts.times do
      finished = Process.waitpid(pid, Process::WNOHANG)
      return finished if finished

      sleep 0.05
    end
    nil
  end

  def write_claim(repo, target, payload)
    path = File.join(@state_root, "claims", repo, "#{target}.json")
    FileUtils.mkdir_p(File.dirname(path))
    record = { "schema_version" => 1, "repo" => repo, "target" => target }.merge(payload)
    File.write(path, "#{JSON.generate(record, ascii_only: true)}\n")
  end

  # Fixtures are written with \u escapes so the bytes on disk stay pure ASCII and
  # remain readable under a non-UTF-8 locale, while still decoding to a non-ASCII
  # string in memory -- which is exactly the case the sync dedup has to survive.
  def write_event(batch_id, event_id, payload)
    path = File.join(@state_root, "events", batch_id, "#{event_id}.json")
    FileUtils.mkdir_p(File.dirname(path))
    record = { "schema_version" => 2, "event_id" => event_id, "batch_id" => batch_id }.merge(payload)
    File.write(path, "#{JSON.generate(record, ascii_only: true)}\n")
  end

  def state_fingerprint
    Dir.glob(File.join(@state_root, "events", "**", "*.json")).map do |path|
      [path, File.read(path)]
    end
  end

  def run_log(*, env: {})
    run_command(COMMAND_ENV.merge("AGENT_COORD_STATE_ROOT" => @state_root).merge(env), "ruby", BIN, "log", *)
  end

  def run_command(*args, stdin_data: nil)
    env = args.first.is_a?(Hash) ? args.shift : {}
    stdout, stderr, status = Open3.capture3(env, *args, stdin_data: stdin_data)
    CommandResult.new(stdout: stdout, stderr: stderr, status: status)
  end
end
