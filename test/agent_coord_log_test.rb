# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"

load File.expand_path("../bin/agent-coord", __dir__)

# `agent-coord log` renders the per-work-item custody trail already carried by
# the event store (issue #129). These tests pin the operator contract: which
# machine and host touched a work item, whether it moved, and when it was last
# worked on -- with no state inference beyond ordering events by timestamp.
class AgentCoordLogTestCase < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "agent-coord")
  CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true)
  LOG_TSV_FIELD_COUNT = 13
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

# The trail itself: what `log` reports for a work item and how it filters.
class AgentCoordLogTest < AgentCoordLogTestCase
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
    assert_includes result.stdout, "no events for shakacode/example#999"
    refute_includes result.stdout, "no events shown"
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

  def test_log_reports_when_zero_limit_suppressed_an_existing_trail
    write_trace

    result = run_log("shakacode/example#104", "--limit", "0")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "no events shown for shakacode/example#104 (--limit 0)"
    refute_includes result.stdout, "no events for shakacode/example#104"
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

  def test_log_json_marks_whether_an_existing_trail_was_suppressed
    write_trace

    suppressed = JSON.parse(run_log("shakacode/example#104", "--limit", "0", "--json").stdout)
    empty = JSON.parse(run_log("shakacode/example#999", "--json").stdout)

    assert_equal true, suppressed.fetch("events_suppressed")
    assert_equal false, empty.fetch("events_suppressed")
    assert_empty suppressed.fetch("events")
    assert_empty empty.fetch("events")
  end

  # Under a non-UTF-8 locale the appended line reads back tagged with the locale
  # encoding, so a row carrying any non-ASCII character (an em dash in a merge
  # note, say) failed the dedup lookup and re-appended on every sync, growing the
  # file without bound. The log always reads and writes UTF-8 regardless of locale.
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

    assert_includes stdout, "no events shown for shakacode/example#10112 (--type error)"
    refute_includes stdout, "no events for shakacode/example#10112"
    refute_includes stdout, "claim active"
  end

  def test_log_tsv_reports_a_suppressed_trail_on_stderr
    write_trace

    result = run_log("shakacode/example#104", "--type", "error", "--format", "tsv")

    assert_empty result.stdout
    assert_includes result.stderr, "no events shown for shakacode/example#104 (--type error)"
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

  def test_log_rejects_a_positional_without_the_work_item_separator
    result = run_log("shakacode/example")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "invalid work item repo"
    refute_includes result.stdout, "no events"
  end

  def test_log_keeps_an_explicitly_empty_positional_unscoped
    write_trace

    result = run_log("")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal 6, result.stdout.lines.length
    assert_includes result.stdout, "shakacode/example#104"
    assert_includes result.stdout, "shakacode/other#7"
  end

  # The mirror is a complete durable copy, not a filtered view. A narrow sync
  # followed by a broader one would append the older events after the newer ones,
  # so the file's last line would no longer be the current state.
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
  # either wrote, and both would then publish the same rows. Asserting on a race
  # would only pass by luck, so this holds the lock and checks that sync waits.
  # The lock lives on a sidecar because the mirror itself is replaced by rename.
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

  # A later sync can still discover an older event -- a concurrent writer, or a
  # backfill -- and appending it blindly would put it after newer rows, so the
  # mirror's last line would stop being the current state.
  # add_target_options already registers --host for every command; registering it
  # again for log collided with that definition. The log help block still
  # describes what --host means here, which is a separate line from the registry.
  def test_log_registers_host_exactly_once
    result = run_command(COMMAND_ENV, "ruby", BIN, "log", "--help")

    assert_equal 1, result.stdout.scan('--host HOST').length, "--host must not be registered twice"
  end

  # --- review findings (PR #131, round 5) ------------------------------------
  def test_log_claim_note_scrubs_control_characters
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "worker\ninjected", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2026-08-01T03:13:03Z")

    stdout = run_log("shakacode/example#10112").stdout

    assert_equal 2, stdout.lines.length, "the claim note must stay on one line"
    assert_includes stdout, "worker injected"
  end

  # --include-synthetic widens the mirror rather than narrowing it, so rejecting
  # it left simulation history with no way to be preserved before gc pruned it.
  # After gc prunes the backend the mirror can be the only copy, so a crash mid
  # rewrite must not be able to destroy it. The replace is atomic, which means no
  # partial file is ever visible at the mirror's path.
  # --- review findings (PR #131, round 6) ------------------------------------
  # add_target_options advertises --repo/--target for every command, so they are
  # accepted here; ignoring them silently dumped the entire feed instead.
  def test_log_scopes_by_repo_and_target_options
    write_trace

    stdout = run_log("--repo", "shakacode/example", "--target", "104").stdout

    assert_equal 5, stdout.lines.length
    refute_includes stdout, "shakacode/other#7"
  end

  def test_log_rejects_malformed_positional_work_items
    ["x/y#1 2", "x/y#", "#1", "x/y#1/2", "x/y#1#2"].each do |work_item|
      result = run_log(work_item)

      assert_equal 1, result.status.exitstatus, "expected #{work_item.inspect} to be rejected"
      assert_includes result.stderr, "invalid work item", "expected #{work_item.inspect} to explain the error"
      refute_includes result.stdout, "no events"
    end
  end

  def test_log_rejects_malformed_repo_and_target_option_values
    [
      ["x/y/z", "1"],
      ["x/y", "1 2"],
      ["", "1"],
      ["x/y", ""]
    ].each do |repo, target|
      result = run_log("--repo", repo, "--target", target)

      assert_equal 1, result.status.exitstatus, "expected #{repo.inspect}##{target.inspect} to be rejected"
      assert_includes result.stderr, "invalid work item"
      refute_includes result.stdout, "no events"
    end
  end

  def test_log_attributes_a_hash_containing_target_option_to_the_target
    result = run_log("--repo", "x/y", "--target", "foo#bar")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "invalid work item target: foo#bar"
    refute_includes result.stderr, "invalid work item repo"
    refute_includes result.stdout, "no events"
  end

  def test_log_accepts_real_colon_and_lane_target_forms
    %w[issue:10112 adhoc:backfill-docs pr:32389 pr:32389:qa 319: adhoc::qa :qa].each do |target|
      positional = run_log("shakacode/example##{target}")
      options = run_log("--repo", "shakacode/example", "--target", target)

      assert_equal 0, positional.status.exitstatus, positional.stderr
      assert_equal 0, options.status.exitstatus, options.stderr
    end
  end

  def test_log_rejects_a_work_item_given_both_ways
    write_trace

    result = run_log("shakacode/example#104", "--repo", "shakacode/example", "--target", "104")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "--repo"
  end

  def test_log_validates_format_on_the_sync_path
    write_trace

    result = run_log("--sync", "--format", "bogus")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "--format"
  end

  # The mirror must order a same-timestamp tie the way the command does, or a
  # grep of the file and a `log` invocation disagree about what happened last.
  # --- review findings (PR #131, round 7) ------------------------------------
  # The row's host column is family-normalized, so comparing the raw flag value
  # against it meant every real recorded spelling silently matched nothing.
  def test_log_host_filter_accepts_recorded_host_spellings
    write_trace

    %w[claude claude-code CLAUDE-CODE].each do |spelling|
      stdout = run_log("--host", spelling).stdout

      assert_equal 2, stdout.lines.length, "expected --host #{spelling} to match the claude family"
    end
  end

  def test_log_host_filter_still_rejects_an_unrelated_host
    write_trace

    assert_includes run_log("--host", "scripted-sim").stdout, "no events"
  end

  # Kernel#Integer reads a leading zero as octal, so 08h and 09h raised an
  # uncaught ArgumentError and 010d silently meant 8 days.
  def test_log_since_accepts_zero_padded_durations
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex", "at" => "2020-01-01T00:00:00Z")

    %w[08h 09m 018d].each do |duration|
      result = run_log("--since", duration)

      assert_equal 0, result.status.exitstatus, "expected --since #{duration} to parse: #{result.stderr}"
      refute_includes result.stderr, "ArgumentError"
    end
  end

  def test_log_since_reads_zero_padded_durations_as_decimal
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex", "at" => "2020-01-01T00:00:00Z")

    # 010d is ten days, not eight; both windows exclude a 2020 event either way,
    # so compare the boundary the option computes instead.
    ten = run_log("--since", "010d", "--json").stdout
    also_ten = run_log("--since", "10d", "--json").stdout

    assert_equal JSON.parse(ten), JSON.parse(also_ten)
  end

  # After --sync --include-synthetic the mirror holds simulation rows that a
  # later default sync keeps; without provenance they read as real work.
  def test_log_marks_synthetic_rows_in_machine_readable_output
    write_event("sim", "s1", "type" => "claim.acquired", "repo" => "sim/race", "target" => "task_two",
                             "machine_id" => "m5", "host" => "scripted-sim", "synthetic" => true,
                             "synthetic_kind" => "simulation", "at" => "2026-08-03T05:00:00Z")

    fields = run_log("sim/race#task_two", "--include-synthetic", "--format", "tsv").stdout.chomp.split("\t")
    payload = JSON.parse(run_log("sim/race#task_two", "--include-synthetic", "--json").stdout)

    assert_includes fields, "true"
    assert_includes fields, "simulation"
    assert_equal true, payload.fetch("events").first.fetch("synthetic")
    assert_equal "simulation", payload.fetch("events").first.fetch("synthetic_kind")
  end

  # An event message is operator- and agent-supplied, so a record carrying an ANSI
  # escape could clear or rewrite the very trail being read. Text and tsv are
  # written straight to a terminal; JSON is left alone because its own encoder
  # escapes control characters.
  def test_log_strips_terminal_control_sequences_from_rendered_output
    hostile = "before\e[2Jafter\u0000\u0007"
    write_event("b1", "e1", "type" => "progress", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex", "message" => hostile,
                            "at" => "2026-08-01T00:00:00Z")

    text = run_log("shakacode/example#5").stdout
    tsv = run_log("shakacode/example#5", "--format", "tsv").stdout

    refute_includes text, "\e", "an escape sequence must never reach the terminal"
    refute_includes tsv, "\e"
    refute_includes text, "\u0000"
    assert_includes text, "before"
    assert_includes text, "after"
  end

  # --- review findings (PR #131, round 9) ------------------------------------
  # A positive limit removes nothing from an already-empty trail, so treating
  # every non-nil limit as "a filter emptied this" hid live custody.
  def test_log_keeps_the_claim_fallback_under_a_positive_limit
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2026-08-01T03:13:03Z")

    assert_includes run_log("shakacode/example#10112", "--limit", "5").stdout, "claim active"
  end

  def test_log_suppresses_the_claim_fallback_under_a_zero_limit
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2026-08-01T03:13:03Z")

    refute_includes run_log("shakacode/example#10112", "--limit", "0").stdout, "claim active"
  end

  # Terminals that recognize C1 act on U+009B/U+009D just as they do on ESC[.
  def test_log_strips_c1_terminal_controls
    write_event("b1", "e1", "type" => "progress", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex",
                            "message" => "before\u009B2Jafter", "at" => "2026-08-01T00:00:00Z")

    stdout = run_log("shakacode/example#5").stdout

    refute_includes stdout, "\u009B"
    assert_includes stdout, "before"
    assert_includes stdout, "after"
  end

  # A --json consumer should read the claim's fields, not re-parse a sentence.
  def test_log_json_reports_the_claim_as_an_object
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "claude-code", "phase" => "implementing", "updated_at" => "2026-08-01T03:13:03Z")

    claim = JSON.parse(run_log("shakacode/example#10112", "--json").stdout).fetch("claim")

    assert_equal "active", claim.fetch("status")
    assert_equal "m5", claim.fetch("machine")
    assert_equal "claude", claim.fetch("host")
    assert_equal "queue-worker", claim.fetch("agent_id")
    assert_equal "implementing", claim.fetch("phase")
    assert_equal "2026-08-01T03:13:03Z", claim.fetch("updated_at")
  end

  # `claim` permits omitting --batch-id, and no lifecycle event is emitted when
  # there is no batch, so a work item can carry stale events and a live claim at
  # once. Reporting the claim only on an empty trail answered "where is it now"
  # with the last thing that happened to leave a trace.
  def test_log_reports_a_claim_newer_than_the_last_event
    write_event("b1", "e1", "type" => "lane_closed", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m1", "host" => "codex", "terminal" => "done",
                            "at" => "2026-08-01T00:00:00Z")
    write_claim("shakacode/example", "5", "status" => "active", "agent_id" => "current-worker",
                                          "machine_id" => "m5", "host" => "codex",
                                          "updated_at" => "2026-08-02T00:00:00Z")

    lines = run_log("shakacode/example#5").stdout.lines

    assert_includes lines.first, "lane_closed"
    assert_includes lines.last, "claim active"
    assert_includes lines.last, "current-worker"
  end

  def test_log_omits_a_claim_older_than_the_last_event
    write_event("b1", "e1", "type" => "lane_closed", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m1", "host" => "codex", "terminal" => "done",
                            "at" => "2026-08-03T00:00:00Z")
    write_claim("shakacode/example", "5", "status" => "released", "agent_id" => "old-worker",
                                          "machine_id" => "m5", "host" => "codex",
                                          "updated_at" => "2026-08-02T00:00:00Z")

    stdout = run_log("shakacode/example#5").stdout

    assert_equal 1, stdout.lines.length
    refute_includes stdout, "claim "
  end

  def test_log_json_includes_a_claim_newer_than_the_last_event
    write_event("b1", "e1", "type" => "lane_closed", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    write_claim("shakacode/example", "5", "status" => "active", "agent_id" => "current-worker",
                                          "machine_id" => "m5", "host" => "codex",
                                          "updated_at" => "2026-08-02T00:00:00Z")

    payload = JSON.parse(run_log("shakacode/example#5", "--json").stdout)

    assert_equal 1, payload.fetch("events").length
    assert_equal "current-worker", payload.fetch("claim").fetch("agent_id")
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

  # The fleet carries claims left active with an expiry long past, so promoting
  # one on recency alone would report expired custody as current.
  def test_log_marks_an_expired_claim_rather_than_presenting_it_as_current
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2026-07-18T12:00:00Z",
                "expires_at" => "2026-07-18T12:42:44Z")

    stdout = run_log("shakacode/example#10112").stdout

    assert_includes stdout, "claim active"
    assert_includes stdout, "lease elapsed"
    assert_includes stdout, "2026-07-18T12:42:44Z"
    refute_includes stdout, "expired", "an elapsed lease is a fact; expired custody is a verdict"
  end

  def test_log_does_not_mark_a_live_claim_as_expired
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2099-01-01T00:00:00Z",
                "expires_at" => "2099-01-01T04:00:00Z")

    refute_includes run_log("shakacode/example#10112").stdout, "lease elapsed"
  end

  def test_log_json_reports_claim_expiry
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2026-07-18T12:00:00Z",
                "expires_at" => "2026-07-18T12:42:44Z")

    claim = JSON.parse(run_log("shakacode/example#10112", "--json").stdout).fetch("claim")

    assert_equal true, claim.fetch("lease_elapsed")
    assert_equal "2026-07-18T12:42:44Z", claim.fetch("expires_at")
  end

  def test_log_marks_a_synthetic_claim
    write_claim("sim/race", "task_two",
                "status" => "active", "agent_id" => "racer0", "machine_id" => "m5",
                "host" => "scripted-sim", "updated_at" => "2099-01-01T00:00:00Z",
                "expires_at" => "2099-01-01T04:00:00Z",
                "synthetic" => true, "synthetic_kind" => "simulation")

    stdout = run_log("sim/race#task_two", "--include-synthetic").stdout
    claim = JSON.parse(run_log("sim/race#task_two", "--include-synthetic", "--json").stdout).fetch("claim")

    assert_includes stdout, "[synthetic]"
    assert_equal true, claim.fetch("synthetic")
    assert_equal "simulation", claim.fetch("synthetic_kind")
  end

  # Claims predating explicit repo/target fields carry them only in the path,
  # which is why claim_status_hash falls back to it. Reading the payload alone
  # meant such a claim could never be matched to the work item it belongs to.
  def test_log_matches_a_legacy_claim_that_carries_its_identity_only_in_the_path
    path = File.join(@state_root, "claims", "shakacode", "example", "77.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.generate({ 'schema_version' => 1, 'status' => 'active',
                                        'agent_id' => 'legacy-worker', 'machine_id' => 'm5',
                                        'host' => 'codex', 'updated_at' => '2099-01-01T00:00:00Z' },
                                      ascii_only: true)}\n")

    stdout = run_log("shakacode/example#77").stdout

    assert_includes stdout, "claim active"
    assert_includes stdout, "legacy-worker"
  end

  # A read failure on a plain query has nothing to do with the mirror; pointing
  # the operator at log.tsv would send them to the wrong file.
  def test_log_reports_an_unreadable_state_root_as_unreadable_state
    write_trace
    FileUtils.chmod(0o000, File.join(@state_root, "events"))

    result = run_log("shakacode/example#104")

    assert_equal 2, result.status.exitstatus
    assert_includes result.stderr, "not readable", result.stderr
    refute_includes result.stderr, "mirror", "a read failure must not point at log.tsv"
    refute_match(%r{\bfrom .*bin/agent-coord:\d+}, result.stderr)
  ensure
    FileUtils.chmod(0o700, File.join(@state_root, "events"))
  end

  def test_log_rejects_json_combined_with_format
    write_trace

    result = run_log("--json", "--format", "tsv")

    assert_equal 1, result.status.exitstatus
    assert_includes result.stderr, "--json"
    assert_includes result.stderr, "--format"
  end

  # Ruby's JSON encoder escapes C0 but not C1: U+009B is emitted raw as UTF-8, so
  # `--json` piped to a terminal carried the same hazard the text renderer strips.
  def test_log_json_output_strips_terminal_controls
    write_event("b1", "e1", "type" => "progress", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m5", "host" => "codex",
                            "message" => "before\u009B2Jafter", "at" => "2026-08-01T00:00:00Z")

    raw = run_log("shakacode/example#5", "--json").stdout

    refute_includes raw, "\u009B"
    assert_includes JSON.parse(raw).fetch("events").first.fetch("detail"), "before"
  end

  # `--machine "$UNSET_VAR"` should not silently match nothing; an empty value is
  # the absence of a filter, not a filter for emptiness.
  def test_log_treats_an_empty_filter_value_as_unset
    write_trace

    %w[--machine --host --type].each do |flag|
      stdout = run_log(flag, "").stdout

      assert_equal 6, stdout.lines.length, "expected #{flag} '' to behave as no filter"
    end
  end

  # Event matching treats an empty filter as unset, so the claim fallback must
  # too, or the two halves of one query disagree about whether it was narrowed.
  def test_log_keeps_the_claim_fallback_under_an_empty_filter_value
    write_claim("shakacode/example", "10112",
                "status" => "active", "agent_id" => "queue-worker", "machine_id" => "m5",
                "host" => "codex", "updated_at" => "2026-08-01T03:13:03Z")

    %w[--machine --host --type].each do |flag|
      assert_includes run_log("shakacode/example#10112", flag, "").stdout, "claim active",
                      "expected #{flag} '' to leave the claim fallback intact"
    end
  end

  # A contract-compliant v2 lane_closed carries identity only in closed_by --
  # contracts/fixtures/v2/lane_closed.json has no top-level agent_id or
  # machine_id -- so reading the top level alone rendered the closer as unknown.
  def test_log_reads_lane_closure_identity_from_closed_by
    write_event("b1", "e1", "type" => "lane_closed", "repo" => "shakacode/example", "target" => "51",
                            "terminal" => "done", "workspace" => "default",
                            "closed_by" => { "agent_id" => "ac-a-0712-0107-i51", "machine" => "m5" },
                            "at" => "2026-07-12T01:07:00Z")

    fields = run_log("shakacode/example#51").stdout.split(/\s+/)

    assert_equal "m5", fields[1]
    assert_equal "ac-a-0712-0107-i51", fields[6]
  end

  def test_log_prefers_top_level_identity_over_closed_by
    write_event("b1", "e1", "type" => "lane_closed", "repo" => "shakacode/example", "target" => "51",
                            "terminal" => "done", "agent_id" => "top-level", "machine_id" => "m1",
                            "closed_by" => { "agent_id" => "nested", "machine" => "m5" },
                            "at" => "2026-07-12T01:07:00Z")

    fields = run_log("shakacode/example#51").stdout.split(/\s+/)

    assert_equal "m1", fields[1]
    assert_equal "top-level", fields[6]
  end

  def test_log_treats_an_empty_since_value_as_unset
    write_trace

    result = run_log("--since", "")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal 6, result.stdout.lines.length
  end

  # Timestamps record whole seconds, so a claim acquired in the same second as
  # the last event ties with it. A strict comparison dropped exactly that case.
  def test_log_reports_a_claim_tied_with_the_latest_event
    write_event("b1", "e1", "type" => "claim.released", "repo" => "shakacode/example", "target" => "5",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    write_claim("shakacode/example", "5", "status" => "active", "agent_id" => "same-second-worker",
                                          "machine_id" => "m5", "host" => "codex",
                                          "updated_at" => "2026-08-01T00:00:00Z",
                                          "expires_at" => "2099-01-01T00:00:00Z")

    assert_includes run_log("shakacode/example#5").stdout, "same-second-worker"
  end
end

# The durable `--sync` mirror: scope, ordering, locking, and replacement.
class AgentCoordLogSyncTest < AgentCoordLogTestCase
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

  # The read path treats an empty flag value as unset; --sync must agree, or a
  # script expanding an unset variable gets a refusal instead of a full mirror.
  def test_log_sync_accepts_empty_filter_values
    write_trace

    %w[--machine --host --type].each do |flag|
      result = run_log("--sync", flag, "")

      assert_equal 0, result.status.exitstatus, "expected --sync #{flag} '' to be accepted: #{result.stderr}"
    end
    assert_equal 6, File.readlines(File.join(@state_root, "log.tsv"), encoding: "UTF-8").length
  end

  # --limit is different: any limit narrows the mirror, including zero, so both
  # stay rejected even though only zero narrows an already-empty trail.
  def test_log_sync_rejects_every_limit
    write_trace

    %w[0 5].each do |limit|
      assert_equal 1, run_log("--sync", "--limit", limit).status.exitstatus,
                   "expected --sync --limit #{limit} to be rejected"
    end
  end

  def test_log_sync_rejects_trail_filters
    write_trace

    [["--since", "1d"], ["--machine", "m5"], ["--host", "codex"],
     ["--type", "claim.acquired"], ["--limit", "2"]].each do |filter|
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

  def test_log_sync_waits_for_an_exclusive_lock_on_the_mirror
    write_trace
    path = File.join(@state_root, "log.tsv")
    File.open("#{path}.lock", File::RDWR | File::CREAT, 0o644) do |holder|
      holder.flock(File::LOCK_EX)
      pid = spawn(COMMAND_ENV.merge("AGENT_COORD_STATE_ROOT" => @state_root),
                  "ruby", BIN, "log", "--sync", out: File::NULL, err: File::NULL)

      assert_nil wait_briefly(pid), "expected --sync to wait for the exclusive lock, not write through it"

      holder.flock(File::LOCK_UN)
      Process.waitpid(pid)
    end

    assert_equal 6, File.readlines(path, encoding: "UTF-8").length
  end

  def test_log_sync_reports_json_when_json_is_requested
    write_trace

    payload = JSON.parse(run_log("--sync", "--json").stdout)

    assert_equal 6, payload.fetch("synced")
    assert payload.fetch("path").end_with?("log.tsv")
  end

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

  def test_log_sync_accepts_include_synthetic
    write_trace
    write_event("sim", "s1", "type" => "claim.acquired", "repo" => "sim/race", "target" => "task_two",
                             "machine_id" => "m5", "host" => "scripted-sim", "synthetic" => true,
                             "at" => "2026-08-03T05:00:00Z")

    result = run_log("--sync", "--include-synthetic")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes File.read(File.join(@state_root, "log.tsv")), "sim/race#task_two"
  end

  def test_log_sync_replaces_the_mirror_atomically
    write_trace
    run_log("--sync")
    path = File.join(@state_root, "log.tsv")
    before = File.read(path)

    write_event("b2", "e9", "type" => "merged", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m1", "host" => "claude-code", "at" => "2026-08-04T00:00:00Z")
    run_log("--sync")

    assert_equal 7, File.readlines(path, encoding: "UTF-8").length
    before.each_line { |line| assert_includes File.read(path), line.chomp }
    assert_empty Dir.glob(File.join(@state_root, "log.tsv.*tmp*")), "no temporary file may be left behind"
  end

  def test_log_sync_breaks_timestamp_ties_by_event_id_like_the_command
    write_event("b1", "zzz", "type" => "phase.changed", "repo" => "shakacode/example", "target" => "5",
                             "machine_id" => "m5", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    run_log("--sync")
    write_event("b1", "aaa", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "5",
                             "machine_id" => "m5", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    run_log("--sync")

    mirror = File.readlines(File.join(@state_root, "log.tsv"), encoding: "UTF-8").map { |l| l.split("\t")[4] }

    assert_equal run_log("shakacode/example#5").stdout.lines.map { |l| l.split(/\s+/)[4] }, mirror
  end

  def test_log_sync_respects_the_umask_for_a_new_mirror
    write_trace
    previous = File.umask(0o077)
    run_log("--sync")

    assert_equal 0o600, File.stat(File.join(@state_root, "log.tsv")).mode & 0o777
  ensure
    File.umask(previous)
  end

  def test_log_sync_preserves_restrictive_mirror_permissions
    write_trace
    run_log("--sync")
    path = File.join(@state_root, "log.tsv")
    File.chmod(0o600, path)

    write_event("b2", "e9", "type" => "merged", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-04T00:00:00Z")
    run_log("--sync")

    assert_equal 0o600, File.stat(path).mode & 0o777
  end

  def test_log_sync_narrowing_error_names_only_real_flags
    write_trace

    stderr = run_log("shakacode/example#104", "--sync").stderr

    refute_includes stderr, "--work-item", "there is no --work-item flag in this CLI"
    assert_includes stderr, "work item"
  end

  def test_log_sync_reports_an_unwritable_mirror_as_an_operational_error
    write_trace
    FileUtils.chmod(0o500, @state_root)

    result = run_log("--sync")

    assert_equal 2, result.status.exitstatus
    refute_includes result.stderr, "SystemCallError"
    refute_match(%r{\bfrom .*bin/agent-coord:\d+}, result.stderr, "must not leak a Ruby backtrace")
  ensure
    FileUtils.chmod(0o700, @state_root)
  end
end

# One GitHub number is one work item, however the target was spelled when it was
# recorded. The store holds the same item as a bare number, as `issue:N`, and as
# `pr:N`, so matching the literal string splits one custody trail into partial
# answers -- the same hazard the repo-casing match already guards against.
class AgentCoordLogWorkItemIdentityTest < AgentCoordLogTestCase
  # A trail for one work item recorded under three spellings, plus a QA sub-lane
  # and a lookalike slug that must stay a different work item.
  def write_mixed_spellings
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "319",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T01:00:00Z")
    write_event("b1", "e2", "type" => "phase.changed", "repo" => "shakacode/example", "target" => "issue:319",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T02:00:00Z")
    write_event("b1", "e3", "type" => "lane_closed", "repo" => "shakacode/example", "target" => "pr:319",
                            "machine_id" => "m2", "host" => "claude-code", "at" => "2026-08-03T03:00:00Z")
    write_event("b1", "e4", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "issue:319:qa",
                            "machine_id" => "m3", "host" => "codex", "at" => "2026-08-03T04:00:00Z")
    write_event("b1", "e5", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "319-fix",
                            "machine_id" => "m9", "host" => "codex", "at" => "2026-08-03T05:00:00Z")
  end

  def json_targets(result)
    JSON.parse(result.stdout).fetch("events").map { |event| event.fetch("work_item") }
  end

  def test_bare_number_query_matches_prefixed_spellings
    write_mixed_spellings

    result = run_log("shakacode/example#319", "--json")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal(
      ["shakacode/example#319", "shakacode/example#issue:319", "shakacode/example#pr:319",
       "shakacode/example#issue:319:qa"],
      json_targets(result)
    )
  end

  def test_prefixed_query_matches_the_bare_spelling
    write_mixed_spellings

    assert_equal 4, json_targets(run_log("shakacode/example#issue:319", "--json")).length
  end

  def test_issue_and_pr_prefixes_are_the_same_work_item
    write_mixed_spellings

    assert_equal(
      json_targets(run_log("shakacode/example#issue:319", "--json")),
      json_targets(run_log("shakacode/example#pr:319", "--json"))
    )
  end

  # Asking for a lane is a narrower question than asking for the work item, so it
  # must not answer with the parent's events.
  def test_explicit_lane_query_matches_only_that_lane
    write_mixed_spellings

    assert_equal ["shakacode/example#issue:319:qa"], json_targets(run_log("shakacode/example#issue:319:qa", "--json"))
  end

  def test_lane_events_roll_up_under_the_bare_work_item
    write_mixed_spellings

    assert_includes json_targets(run_log("shakacode/example#319", "--json")), "shakacode/example#issue:319:qa"
  end

  # `319-fix` is a slug, not a lane of 319. Prefix-stripping must not widen into
  # substring matching.
  def test_lookalike_slug_is_a_different_work_item
    write_mixed_spellings

    refute_includes json_targets(run_log("shakacode/example#319", "--json")), "shakacode/example#319-fix"
  end

  def test_slug_target_still_matches_itself
    write_mixed_spellings

    assert_equal ["shakacode/example#319-fix"], json_targets(run_log("shakacode/example#319-fix", "--json"))
  end

  def test_claim_recorded_under_a_prefixed_target_is_found_by_the_bare_query
    write_mixed_spellings
    write_claim("shakacode/example", "issue:319", "status" => "active", "agent_id" => "acd-worker",
                                                  "updated_at" => "2026-08-03T06:00:00Z")

    claim = JSON.parse(run_log("shakacode/example#319", "--json").stdout).fetch("claim")

    assert_equal "acd-worker", claim.fetch("agent_id")
  end

  # A JSON consumer sees only the payload, so "searched everything and found
  # nothing" must not render identically to "could not search".
  def test_json_reports_the_spellings_that_matched
    write_mixed_spellings

    payload = JSON.parse(run_log("shakacode/example#319", "--json").stdout)

    assert_equal ["319", "issue:319", "issue:319:qa", "pr:319"], payload.dig("work_item", "matched_targets").sort
  end

  # Claims are cleared on release, so a finished work item has events and no live
  # claim. That is the case target-scoped status cannot tell from "never worked",
  # and the whole reason this trail has to be reachable by any spelling.
  def test_finished_work_item_reports_its_events_with_no_live_claim
    write_mixed_spellings

    payload = JSON.parse(run_log("shakacode/example#319", "--json").stdout)

    assert_nil payload["claim"]
    refute_empty payload.fetch("events")
    assert_equal "complete", payload.fetch("trail")
  end

  def test_json_reports_a_complete_trail_with_no_records_as_searched
    write_mixed_spellings

    payload = JSON.parse(run_log("shakacode/example#999", "--json").stdout)

    assert_empty payload.fetch("events")
    assert_equal "complete", payload.fetch("trail")
    assert_empty payload.dig("work_item", "matched_targets")
  end
end

# Rolling lanes into the item is right for history and wrong for custody: a lane
# holds its own lease, so a parent and its lane can both be live at once. The
# fleet does exactly this (`pr:32389` and `pr:32389:qa`, both active).
class AgentCoordLogConcurrentLaneClaimTest < AgentCoordLogTestCase
  def write_parent_and_lane_claims
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "issue:319",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T01:00:00Z")
    write_claim("shakacode/example", "319", "status" => "active", "agent_id" => "parent-worker",
                                            "updated_at" => "2026-08-03T02:00:00Z")
    # Newer, so a max_by over both would prefer it and hide the parent.
    write_claim("shakacode/example", "issue:319:qa", "status" => "active", "agent_id" => "qa-worker",
                                                     "updated_at" => "2026-08-03T05:00:00Z")
  end

  def claim_for(target)
    JSON.parse(run_log("shakacode/example##{target}", "--json").stdout)["claim"]
  end

  def test_item_query_reports_the_item_claim_not_a_newer_lane_claim
    write_parent_and_lane_claims

    assert_equal "parent-worker", claim_for("319").fetch("agent_id")
  end

  def test_prefixed_item_query_still_finds_the_bare_item_claim
    write_parent_and_lane_claims

    assert_equal "parent-worker", claim_for("issue:319").fetch("agent_id")
  end

  def test_lane_query_reports_the_lane_claim
    write_parent_and_lane_claims

    assert_equal "qa-worker", claim_for("issue:319:qa").fetch("agent_id")
  end

  # A live claim with no events is an explicitly supported fallback. Reporting the
  # claim while also reporting that nothing matched contradicts itself.
  def test_claim_only_work_item_reports_the_claim_target_as_matched
    write_claim("shakacode/example", "issue:404", "status" => "active", "agent_id" => "solo-worker",
                                                  "updated_at" => "2026-08-03T02:00:00Z")

    payload = JSON.parse(run_log("shakacode/example#404", "--json").stdout)

    assert_equal "solo-worker", payload.fetch("claim").fetch("agent_id")
    assert_empty payload.fetch("events")
    assert_equal ["issue:404"], payload.dig("work_item", "matched_targets")
  end

  # `319:` is a legal claim segment. split(":") drops the trailing empty field, so
  # without an explicit limit it would collapse into the bare item and two distinct
  # claim keys would answer as one.
  def test_trailing_colon_target_is_not_the_bare_work_item
    write_claim("shakacode/example", "319", "status" => "active", "agent_id" => "parent-worker",
                                            "updated_at" => "2026-08-03T02:00:00Z")
    write_claim("shakacode/example", "319:", "status" => "active", "agent_id" => "colon-worker",
                                             "updated_at" => "2026-08-03T05:00:00Z")

    assert_equal "parent-worker", claim_for("319").fetch("agent_id")
  end
end

# Folding aliases finds more claims, and must not therefore report fewer holders.
# `claim` writes raw target paths, so `9832` and `pr:9832` are independently
# claimable and the fleet does hold both live under different agents.
class AgentCoordLogAliasClaimTest < AgentCoordLogTestCase
  def write_alias_claims
    write_claim("shakacode/example", "9832", "status" => "active", "agent_id" => "bare-holder",
                                             "updated_at" => "2026-08-03T02:00:00Z")
    write_claim("shakacode/example", "pr:9832", "status" => "active", "agent_id" => "prefixed-holder",
                                                "updated_at" => "2026-08-03T05:00:00Z")
  end

  def payload_for(target)
    JSON.parse(run_log("shakacode/example##{target}", "--json").stdout)
  end

  def test_every_alias_holder_is_reported_not_just_the_newest
    write_alias_claims

    holders = payload_for("9832").fetch("claims").map { |claim| claim.fetch("agent_id") }

    assert_equal %w[bare-holder prefixed-holder], holders.sort
  end

  def test_singular_claim_stays_the_newest_for_existing_consumers
    write_alias_claims

    assert_equal "prefixed-holder", payload_for("9832").fetch("claim").fetch("agent_id")
  end

  def test_text_output_shows_every_alias_holder
    write_alias_claims

    stdout = run_log("shakacode/example#9832").stdout

    assert_includes stdout, "bare-holder"
    assert_includes stdout, "prefixed-holder"
  end

  def test_a_single_holder_still_reports_one_claim
    write_claim("shakacode/example", "issue:9832", "status" => "active", "agent_id" => "only-holder",
                                                   "updated_at" => "2026-08-03T02:00:00Z")

    payload = payload_for("9832")

    assert_equal "only-holder", payload.fetch("claim").fetch("agent_id")
    assert_equal(["only-holder"], payload.fetch("claims").map { |claim| claim.fetch("agent_id") })
  end

  # A lane event cannot supersede the parent's separately leased custody, so it
  # must not decide whether the parent claim is still the latest thing known.
  def test_a_newer_lane_event_does_not_suppress_the_parent_claim
    write_claim("shakacode/example", "319", "status" => "active", "agent_id" => "parent-holder",
                                            "updated_at" => "2026-08-03T02:00:00Z")
    write_event("b1", "e1", "type" => "phase.changed", "repo" => "shakacode/example",
                            "target" => "issue:319:qa", "machine_id" => "m1", "host" => "codex",
                            "at" => "2026-08-03T09:00:00Z")

    assert_equal "parent-holder", payload_for("319").fetch("claim").fetch("agent_id")
  end

  # adhoc ids are operator-chosen slugs, not GitHub numbers, so a numeric one is
  # its own work item and must not merge with the issue of the same number.
  def test_numeric_adhoc_target_is_not_the_github_item
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "issue:319",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T01:00:00Z")
    write_event("b1", "e2", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "adhoc:319",
                            "machine_id" => "m2", "host" => "codex", "at" => "2026-08-03T02:00:00Z")

    assert_equal ["issue:319"], payload_for("319").dig("work_item", "matched_targets")
    assert_equal ["adhoc:319"], payload_for("adhoc:319").dig("work_item", "matched_targets")
  end

  # The slug case that made adhoc foldable in the first place still folds.
  def test_slug_adhoc_target_still_folds_with_its_bare_spelling
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example",
                            "target" => "20260731-backend-policy", "machine_id" => "m1", "host" => "codex",
                            "at" => "2026-08-03T01:00:00Z")
    write_event("b1", "e2", "type" => "phase.changed", "repo" => "shakacode/example",
                            "target" => "adhoc:20260731-backend-policy", "machine_id" => "m1", "host" => "codex",
                            "at" => "2026-08-03T02:00:00Z")

    assert_equal 2, payload_for("20260731-backend-policy").fetch("events").length
  end
end

# The difference between "two records" and "two holders" is the exact claim key.
class AgentCoordLogClaimKeyTest < AgentCoordLogTestCase
  def test_one_key_recorded_under_two_casings_reports_only_the_newest
    write_claim("shakacode/example", "9832", "status" => "released", "agent_id" => "old-worker",
                                             "updated_at" => "2026-07-01T00:00:00Z")
    # Same lease, repo casing differs, so this is the same key recorded twice.
    write_claim("ShakaCode/example", "9832", "status" => "active", "agent_id" => "current-worker",
                                             "updated_at" => "2026-08-01T00:00:00Z")

    holders = JSON.parse(run_log("shakacode/example#9832", "--json").stdout)
                  .fetch("claims").map { |claim| claim.fetch("agent_id") }

    assert_equal ["current-worker"], holders
  end

  def test_two_distinct_keys_report_both_holders
    write_claim("shakacode/example", "9832", "status" => "active", "agent_id" => "bare-holder",
                                             "updated_at" => "2026-07-01T00:00:00Z")
    write_claim("shakacode/example", "pr:9832", "status" => "active", "agent_id" => "prefixed-holder",
                                                "updated_at" => "2026-08-01T00:00:00Z")

    holders = JSON.parse(run_log("shakacode/example#9832", "--json").stdout)
                  .fetch("claims").map { |claim| claim.fetch("agent_id") }

    assert_equal %w[bare-holder prefixed-holder], holders.sort
  end
end

# Aliases are separate leases, so neither the trail nor another alias may decide
# whether one of them is still current.
class AgentCoordLogAliasFreshnessTest < AgentCoordLogTestCase
  def test_an_event_on_one_alias_does_not_suppress_the_other_alias_claim
    write_claim("shakacode/example", "1", "status" => "active", "agent_id" => "bare-holder",
                                          "updated_at" => "2026-08-01T00:00:00Z")
    write_claim("shakacode/example", "pr:1", "status" => "active", "agent_id" => "prefixed-holder",
                                             "updated_at" => "2026-08-10T00:00:00Z")
    # Newer than the bare lease, so a lane-only comparison would suppress it, but
    # it belongs to the prefixed alias and is older than that alias's own lease.
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "pr:1",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-09T00:00:00Z")

    holders = JSON.parse(run_log("shakacode/example#1", "--json").stdout)
                  .fetch("claims").map { |claim| claim.fetch("agent_id") }

    assert_equal %w[bare-holder prefixed-holder], holders.sort
  end

  def test_an_alias_claim_older_than_its_own_event_is_still_superseded
    write_claim("shakacode/example", "1", "status" => "active", "agent_id" => "bare-holder",
                                          "updated_at" => "2026-08-01T00:00:00Z")
    write_claim("shakacode/example", "pr:1", "status" => "active", "agent_id" => "prefixed-holder",
                                             "updated_at" => "2026-08-02T00:00:00Z")
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "pr:1",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-09T00:00:00Z")

    holders = JSON.parse(run_log("shakacode/example#1", "--json").stdout)
                  .fetch("claims").map { |claim| claim.fetch("agent_id") }

    assert_equal ["bare-holder"], holders, "the prefixed lease is older than its own event"
  end

  def test_an_event_on_the_claims_own_key_still_supersedes_it
    write_claim("shakacode/example", "1", "status" => "active", "agent_id" => "bare-holder",
                                          "updated_at" => "2026-08-01T00:00:00Z")
    write_event("b1", "e1", "type" => "claim.released", "repo" => "shakacode/example", "target" => "1",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-09T00:00:00Z")

    assert_nil JSON.parse(run_log("shakacode/example#1", "--json").stdout)["claim"]
  end
end

# Declining to strip a numeric `adhoc:` prefix must keep it in the base, not turn
# the number into a lane of a work item called "adhoc".
class AgentCoordLogNumericAdhocTest < AgentCoordLogTestCase
  def write_adhoc_events
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "adhoc:319",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T01:00:00Z")
    write_event("b1", "e2", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "adhoc",
                            "machine_id" => "m2", "host" => "codex", "at" => "2026-08-03T02:00:00Z")
    write_event("b1", "e3", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "adhoc:319:qa",
                            "machine_id" => "m3", "host" => "codex", "at" => "2026-08-03T03:00:00Z")
  end

  def matched(target)
    JSON.parse(run_log("shakacode/example##{target}", "--json").stdout).dig("work_item", "matched_targets")
  end

  def test_bare_adhoc_query_does_not_sweep_in_numeric_adhoc_items
    write_adhoc_events

    assert_equal ["adhoc"], matched("adhoc")
  end

  def test_numeric_adhoc_item_covers_its_own_lane
    write_adhoc_events

    assert_equal ["adhoc:319", "adhoc:319:qa"], matched("adhoc:319")
  end

  def test_numeric_adhoc_lane_query_stays_narrow
    write_adhoc_events

    assert_equal ["adhoc:319:qa"], matched("adhoc:319:qa")
  end

  def test_numeric_adhoc_item_is_still_not_the_github_item
    write_adhoc_events
    write_event("b1", "e4", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "issue:319",
                            "machine_id" => "m4", "host" => "codex", "at" => "2026-08-03T04:00:00Z")

    assert_equal ["issue:319"], matched("319")
  end
end

# A kind prefix decorates an identifier. With no identifier to decorate there is
# nothing to strip, so `adhoc::qa` must stay distinct from the separately keyed
# `:qa` rather than folding onto it.
class AgentCoordLogEmptyKindIdentifierTest < AgentCoordLogTestCase
  def write_empty_identifier_events
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "adhoc::qa",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-04T01:00:00Z")
    write_event("b1", "e2", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => ":qa",
                            "machine_id" => "m2", "host" => "codex", "at" => "2026-08-04T02:00:00Z")
  end

  def matched(target)
    JSON.parse(run_log("shakacode/example##{target}", "--json").stdout).dig("work_item", "matched_targets")
  end

  def test_empty_adhoc_identifier_is_not_the_bare_lane_item
    write_empty_identifier_events

    assert_equal ["adhoc::qa"], matched("adhoc::qa")
  end

  def test_bare_lane_item_does_not_absorb_the_empty_adhoc_identifier
    write_empty_identifier_events

    assert_equal [":qa"], matched(":qa")
  end

  # The guard is on the id, not on the lane that follows it, so a bare `adhoc:`
  # is kept whole for the same reason and does not answer for the empty base.
  def test_bare_adhoc_prefix_with_no_id_stays_whole
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "adhoc:",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-04T01:00:00Z")
    write_event("b1", "e2", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "",
                            "machine_id" => "m2", "host" => "codex", "at" => "2026-08-04T02:00:00Z")

    assert_equal ["adhoc:"], matched("adhoc:")
  end
end

# --limit trims what is displayed. It must not trim the evidence that decides
# whether a claim is still current, or a stale lease reads as live custody.
class AgentCoordLogLimitFreshnessTest < AgentCoordLogTestCase
  def write_superseded_alias_claim
    write_claim("shakacode/example", "pr:1", "status" => "active", "agent_id" => "stale-holder",
                                             "updated_at" => "2026-08-01T00:00:00Z")
    write_event("b1", "e2", "type" => "claim.released", "repo" => "shakacode/example", "target" => "pr:1",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-02T00:00:00Z")
    # Newer still, and on a different alias, so --limit 1 keeps only this one.
    write_event("b1", "e3", "type" => "phase.changed", "repo" => "shakacode/example", "target" => "1",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T00:00:00Z")
  end

  def claims_for(*)
    payload = JSON.parse(run_log("shakacode/example#1", "--json", *).stdout)
    (payload["claims"] || []).map { |claim| claim.fetch("agent_id") }
  end

  def test_a_release_dropped_by_the_limit_still_supersedes_the_claim
    write_superseded_alias_claim

    assert_empty claims_for("--limit", "1")
  end

  def test_the_unlimited_answer_is_unchanged
    write_superseded_alias_claim

    assert_empty claims_for
  end

  def test_the_limit_still_trims_the_displayed_trail
    write_superseded_alias_claim

    events = JSON.parse(run_log("shakacode/example#1", "--json", "--limit", "1").stdout).fetch("events")

    assert_equal 1, events.length
  end
end

# Two holders are only actionable if you can tell which lease each one holds.
class AgentCoordLogClaimTargetTest < AgentCoordLogTestCase
  def write_two_holders
    write_claim("shakacode/example", "1", "status" => "active", "agent_id" => "bare-holder",
                                          "updated_at" => "2026-08-01T00:00:00Z")
    write_claim("shakacode/example", "pr:1", "status" => "active", "agent_id" => "prefixed-holder",
                                             "updated_at" => "2026-08-02T00:00:00Z")
  end

  def test_each_emitted_claim_names_its_own_lease_key
    write_two_holders

    claims = JSON.parse(run_log("shakacode/example#1", "--json").stdout).fetch("claims")

    assert_equal({ "bare-holder" => "1", "prefixed-holder" => "pr:1" },
                 claims.to_h { |claim| [claim.fetch("agent_id"), claim.fetch("target")] })
  end

  def test_text_output_names_the_lease_key_on_each_claim_line
    write_two_holders

    lines = run_log("shakacode/example#1").stdout.lines.select { |line| line.start_with?("claim ") }

    assert_equal 2, lines.length
    assert(lines.any? { |line| line.include?("bare-holder") && line.include?(" 1 ") })
    assert(lines.any? { |line| line.include?("prefixed-holder") && line.include?(" pr:1 ") })
  end
end

# The trail reads oldest-first and the last line is the current state. Claim
# trailer lines are part of that reading, so they follow the same direction.
class AgentCoordLogClaimOrderTest < AgentCoordLogTestCase
  def write_two_live_holders
    write_claim("shakacode/example", "1", "status" => "active", "agent_id" => "older-holder",
                                          "updated_at" => "2026-08-01T00:00:00Z")
    write_claim("shakacode/example", "pr:1", "status" => "active", "agent_id" => "newer-holder",
                                             "updated_at" => "2026-08-02T00:00:00Z")
  end

  def test_text_claim_lines_read_oldest_first
    write_two_live_holders

    holders = run_log("shakacode/example#1").stdout.lines
                                            .select { |line| line.start_with?("claim ") }
                                            .map { |line| line[/\b\w+-holder\b/] }

    assert_equal %w[older-holder newer-holder], holders
  end

  def test_singular_json_claim_is_still_the_newest
    write_two_live_holders

    payload = JSON.parse(run_log("shakacode/example#1", "--json").stdout)

    assert_equal "newer-holder", payload.fetch("claim").fetch("agent_id")
    assert_equal(%w[older-holder newer-holder],
                 payload.fetch("claims").map { |claim| claim.fetch("agent_id") })
  end
end

# `issue:`/`pr:` are decoration on a GitHub number. Ahead of a slug they are not
# decoration, and stripping them would merge two separately keyed records.
class AgentCoordLogNonNumericKindTest < AgentCoordLogTestCase
  def write_slug_events
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "foo",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T01:00:00Z")
    write_event("b1", "e2", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "issue:foo",
                            "machine_id" => "m2", "host" => "codex", "at" => "2026-08-03T02:00:00Z")
  end

  def matched(target)
    JSON.parse(run_log("shakacode/example##{target}", "--json").stdout).dig("work_item", "matched_targets")
  end

  def test_a_slug_and_its_prefixed_spelling_are_different_work_items
    write_slug_events

    assert_equal ["foo"], matched("foo")
    assert_equal ["issue:foo"], matched("issue:foo")
  end

  def test_numeric_ids_still_fold_across_prefixes
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "319",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T01:00:00Z")
    write_event("b1", "e2", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "issue:319",
                            "machine_id" => "m2", "host" => "codex", "at" => "2026-08-03T02:00:00Z")

    assert_equal ["319", "issue:319"], matched("pr:319")
  end

  def test_a_lane_under_a_numeric_id_still_folds
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "issue:319:qa",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T01:00:00Z")

    assert_equal ["issue:319:qa"], matched("319")
  end
end

# matched_targets is provenance for the search, not a description of the rendered
# rows, so a display limit must not shrink it.
class AgentCoordLogLimitProvenanceTest < AgentCoordLogTestCase
  def write_two_spellings
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "issue:1",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    write_event("b1", "e2", "type" => "phase.changed", "repo" => "shakacode/example", "target" => "pr:1",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-02T00:00:00Z")
  end

  def test_the_limit_does_not_drop_spellings_from_the_provenance
    write_two_spellings

    payload = JSON.parse(run_log("shakacode/example#1", "--json", "--limit", "1").stdout)

    assert_equal ["issue:1", "pr:1"], payload.dig("work_item", "matched_targets")
    assert_equal 1, payload.fetch("events").length, "the displayed trail is still limited"
  end

  def test_the_unlimited_provenance_is_the_same
    write_two_spellings

    payload = JSON.parse(run_log("shakacode/example#1", "--json").stdout)

    assert_equal ["issue:1", "pr:1"], payload.dig("work_item", "matched_targets")
  end
end

# A damaged live event record must shorten only that record, not the whole
# read-only custody trail. The shortened result is still incomplete and cannot
# be persisted by --sync.
class AgentCoordLogLiveRecordResilienceTest < AgentCoordLogTestCase
  TSV_EVENT_ID_COLUMN = 10

  # A single unreadable live record must not hide the readable custody events
  # beside it. The warning also marks the trail incomplete so --sync cannot
  # persist the shortened view as a complete mirror.
  def test_log_degrades_when_a_live_record_file_is_unreadable
    write_trace
    unreadable = File.join(@state_root, "events", "b1", "e3.json")
    FileUtils.chmod(0o000, unreadable)

    result = run_log("shakacode/example#104", "--format", "tsv")
    sync = run_log("--sync")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "events unreadable"
    assert_includes result.stderr, "this trail may be incomplete"
    refute_match(/SystemCallError|Errno::/, result.stderr, "must not leak the exception class")
    refute_match(%r{\bfrom .*bin/agent-coord:\d+}, result.stderr, "must not leak a Ruby backtrace")
    assert_equal %w[e1 e2 e4 e5], tsv_rows_event_ids(result), "only the unreadable event is omitted"
    assert_equal 2, sync.status.exitstatus, "a mirror must not be written over the shortened trail"
    assert_includes sync.stderr, "refusing to sync an incomplete trail: events"
    refute_path_exists File.join(@state_root, "log.tsv")
  ensure
    FileUtils.chmod(0o600, unreadable) if unreadable && File.exist?(unreadable)
  end

  # A JSON value can parse successfully without being an event object. Report
  # that record, keep its readable siblings, and make the incomplete trail
  # ineligible for --sync instead of leaking a raw TypeError.
  def test_log_reports_a_live_record_that_is_not_an_object
    write_trace
    write_raw_event("b1", "array", [1, 2, 3])

    result = run_log("shakacode/example#104", "--format", "tsv")
    sync = run_log("--sync")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "live event record is not an object at events/b1/array.json"
    assert_includes result.stderr, "this trail may be incomplete"
    refute_match(/TypeError|no implicit conversion/, result.stderr, "must not leak a raw type error")
    refute_match(%r{\bfrom .*bin/agent-coord:\d+}, result.stderr, "must not leak a Ruby backtrace")
    assert_equal %w[e1 e2 e3 e4 e5], tsv_rows_event_ids(result), "the readable events must survive"
    assert_equal 2, sync.status.exitstatus, "a mirror must not be written over the shortened trail"
    assert_includes sync.stderr, "refusing to sync an incomplete trail: events"
    refute_path_exists File.join(@state_root, "log.tsv")
  end

  # Unix filenames can carry bytes that are not valid UTF-8. The record is
  # already being reported as incomplete, so its diagnostic path must be made
  # printable instead of letting the scrubber raise and hide every good event.
  def test_log_scrubs_invalid_utf8_from_a_non_object_live_record_path
    good = AgentCoord::StoredJson.new(
      path: "events/b1/e1.json",
      data: { "event_id" => "e1", "batch_id" => "b1", "type" => "claim.acquired",
              "repo" => "shakacode/example", "target" => "104", "at" => "2026-08-03T02:40:16Z" }
    )
    bad = AgentCoord::StoredJson.new(path: "events/b1/bad-\xE2.json".b, data: [1, 2, 3])
    store = Object.new
    store.define_singleton_method(:list_json) { |prefix, &_handler| prefix == "events" ? [good, bad] : [] }
    stderr = StringIO.new
    runner = AgentCoord::Runner.new([], stderr: stderr)

    rows = runner.send(:log_event_rows, store)

    assert_equal ["e1"], rows.map { |row| row.fetch("event_id") }, "the readable event must survive"
    assert_predicate stderr.string, :valid_encoding?
    assert_includes stderr.string, "live event record is not an object at events/b1/bad-\uFFFD.json"
    refute_match(/ArgumentError|invalid byte sequence/, stderr.string, "must not leak the failed scrub")
    assert_equal "events", runner.send(:log_incomplete_prefixes), "--sync must see an incomplete trail"
  end

  private

  def write_raw_event(batch_id, name, record)
    path = File.join(@state_root, "events", batch_id, "#{name}.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.generate(record)}\n")
  end

  def tsv_rows_event_ids(result)
    result.stdout.lines.map { |line| line.split("\t").fetch(TSV_EVENT_ID_COLUMN) }
  end
end

# A valid JSON value under claims/ is not necessarily a claim object. The
# read-only log command must keep the readable custody data instead of leaking
# a Ruby type error from the damaged record.
class AgentCoordLogClaimRecordResilienceTest < AgentCoordLogTestCase
  def test_log_reports_a_claim_record_that_is_not_an_object
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T02:40:16Z")
    write_claim("shakacode/example", "104",
                "status" => "active", "agent_id" => "readable-worker", "machine_id" => "m1",
                "host" => "codex", "updated_at" => "2026-08-03T03:00:00Z")
    write_raw_claim("issue:104", [1, 2, 3])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "live claim record is not an object at claims/shakacode/example/issue:104.json"
    assert_includes result.stderr, "this trail may be incomplete"
    refute_match(/TypeError|no implicit conversion/, result.stderr, "must not leak a raw type error")
    refute_match(%r{\bfrom .*bin/agent-coord:\d+}, result.stderr, "must not leak a Ruby backtrace")
    assert_includes result.stdout, "claim active"
    assert_includes result.stdout, "readable-worker"
    assert_includes result.stdout, "claim.acquired"
  end

  def test_log_keeps_readable_siblings_in_every_format_around_scalar_claim_records
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T02:40:16Z")
    write_claim("shakacode/example", "104",
                "status" => "active", "agent_id" => "readable-worker", "machine_id" => "m1",
                "host" => "codex", "updated_at" => "2026-08-03T03:00:00Z")
    [nil, false, 7, "claim"].each do |record|
      write_raw_claim("issue:104", record)

      text = run_log("shakacode/example#104")
      tsv = run_log("shakacode/example#104", "--format", "tsv")
      json = run_log("shakacode/example#104", "--json")

      [text, tsv, json].each do |result|
        assert_equal 0, result.status.exitstatus, result.stderr
        assert_includes result.stderr,
                        "live claim record is not an object at claims/shakacode/example/issue:104.json"
        refute_match(/TypeError|NoMethodError|undefined method|no implicit conversion/, result.stderr)
        refute_match(%r{\bfrom .*bin/agent-coord:\d+}, result.stderr)
      end
      assert_includes text.stdout, "claim.acquired"
      assert_includes text.stdout, "readable-worker"
      assert_includes tsv.stdout, "\te1\t"
      assert_includes tsv.stderr, "readable-worker"
      payload = JSON.parse(json.stdout)
      event_ids = payload.fetch("events").map { |event| event.fetch("event_id") }
      assert_equal ["e1"], event_ids
      assert_equal "readable-worker", payload.fetch("claim").fetch("agent_id")
      assert_equal "incomplete", payload.fetch("trail")
    end
  end

  def test_log_scrubs_a_control_character_from_a_non_object_claim_path_through_the_cli
    write_raw_claim("issue:104\n", [1, 2, 3])

    result = run_log("shakacode/example#104", "--json")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_predicate result.stderr, :valid_encoding?
    assert_includes result.stderr, "live claim record is not an object at claims/shakacode/example/issue:104 .json"
    refute_match(%r{ArgumentError|invalid byte sequence|bin/agent-coord:\d+}, result.stderr)
    assert_equal "incomplete", JSON.parse(result.stdout).fetch("trail")
  end

  def test_log_ignores_a_non_object_claim_outside_the_scoped_work_item
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T02:40:16Z")
    write_claim("shakacode/example", "104",
                "status" => "active", "agent_id" => "readable-worker", "machine_id" => "m1",
                "host" => "codex", "updated_at" => "2026-08-03T03:00:00Z")
    write_raw_claim("unrelated", [1, 2, 3])

    result = run_log("shakacode/example#104", "--json")

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stderr, "claims/shakacode/example/unrelated.json"
    payload = JSON.parse(result.stdout)
    assert_equal "complete", payload.fetch("trail")
    assert_equal "readable-worker", payload.fetch("claim").fetch("agent_id")
  end

  # An invalidly encoded path cannot prove that a malformed claim belongs to a
  # different work item. Degrade conservatively and scrub the diagnostic.
  def test_log_scrubs_invalid_utf8_before_matching_a_non_object_claim_path
    good = AgentCoord::StoredJson.new(
      path: "claims/shakacode/example/issue:104.json",
      data: { "repo" => "shakacode/example", "target" => "issue:104" }
    )
    invalid_path = "claims/shakacode/example/issue:104-\xE2.json".b.force_encoding(Encoding::UTF_8)
    bad = AgentCoord::StoredJson.new(path: invalid_path, data: [1, 2, 3])
    store = Object.new
    store.define_singleton_method(:list_json) { |_prefix, &_handler| [good, bad] }
    stderr = StringIO.new
    runner = AgentCoord::Runner.new([], stderr: stderr)
    wanted = runner.send(:log_identity, "shakacode/example", "104")

    claims = runner.send(:log_claim_entries, store, wanted_identity: wanted)

    assert_equal [good], claims
    assert_predicate stderr.string, :valid_encoding?
    assert_includes stderr.string,
                    "live claim record is not an object at claims/shakacode/example/issue:104-\uFFFD.json"
    refute_match(/ArgumentError|invalid byte sequence/, stderr.string)
    assert_equal "claims", runner.send(:log_incomplete_prefixes)
  end

  def test_log_refuses_to_sync_past_a_non_object_claim_record
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m1", "host" => "codex", "at" => "2026-08-03T02:40:16Z")
    write_raw_claim("null", nil)

    result = run_log("--sync")

    assert_equal 2, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "live claim record is not an object at claims/shakacode/example/null.json"
    assert_includes result.stderr, "refusing to sync an incomplete trail: claims"
    refute_path_exists File.join(@state_root, "log.tsv")
  end

  private

  def write_raw_claim(name, record)
    path = File.join(@state_root, "claims", "shakacode", "example", "#{name}.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.generate(record)}\n")
  end
end

# Invalid encoding is different from an unreadable or structurally malformed
# record: identity cannot be compared safely, so omitting it would claim that a
# partial trail is complete. The log request must fail before rendering any
# healthy sibling and must never rewrite the stored bytes.
class AgentCoordLogInvalidEncodingTest < AgentCoordLogTestCase
  LOCALES = %w[C C.UTF-8].freeze

  def test_log_fails_closed_on_invalid_utf8_live_event_values
    write_event("b1", "healthy", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "42",
                                 "machine_id" => "m5", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    corrupt = write_corrupt_event("corrupt-repo", "corrupt-\xFF".b)
    original = File.binread(corrupt)

    LOCALES.each do |locale|
      result = run_log("shakacode/example#42", "--format", "tsv", env: { "LC_ALL" => locale, "LANG" => locale })

      assert_equal 2, result.status.exitstatus, locale
      assert_empty result.stdout, "a corrupt record must block the healthy sibling under #{locale}"
      assert_equal "state unreadable: invalid UTF-8 in persisted log record at events/b1/corrupt.json\n",
                   result.stderr, locale
      assert_predicate result.stderr, :valid_encoding?, locale
      refute_match(/ArgumentError|Encoding::CompatibilityError|JSON::GeneratorError/, result.stderr, locale)
      refute_match(%r{\bfrom .*bin/agent-coord:\d+}, result.stderr, locale)
      assert_equal original, File.binread(corrupt), "source bytes changed under #{locale}"
    end
  end

  def test_log_fails_closed_on_recursively_invalid_utf8_archive_keys
    write_event("b2", "healthy", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "42",
                                 "machine_id" => "m5", "host" => "codex", "at" => "2026-08-02T00:00:00Z")
    corrupt = write_corrupt_archive_key
    original = File.binread(corrupt)

    LOCALES.each do |locale|
      result = run_log("shakacode/example#42", "--format", "tsv", env: { "LC_ALL" => locale, "LANG" => locale })

      assert_equal 2, result.status.exitstatus, locale
      assert_empty result.stdout, "a corrupt archive must block the healthy live event under #{locale}"
      assert_equal "state unreadable: invalid UTF-8 in persisted log record at " \
                   "archive/events/b1/compacted.json\n", result.stderr, locale
      assert_predicate result.stderr, :valid_encoding?, locale
      refute_match(/ArgumentError|Encoding::CompatibilityError|JSON::GeneratorError/, result.stderr, locale)
      refute_match(%r{\bfrom .*bin/agent-coord:\d+}, result.stderr, locale)
      assert_equal original, File.binread(corrupt), "source bytes changed under #{locale}"
    end
  end

  private

  def write_corrupt_event(needle, replacement)
    path = File.join(@state_root, "events", "b1", "corrupt.json")
    FileUtils.mkdir_p(File.dirname(path))
    record = {
      "schema_version" => 2,
      "event_id" => "corrupt",
      "batch_id" => "b1",
      "type" => "phase.changed",
      "repo" => "shakacode/#{needle}",
      "target" => "42",
      "phase" => "qa",
      "at" => "2026-08-01T01:00:00Z"
    }
    bytes = "#{JSON.generate(record)}\n".b.sub(needle.b, replacement)
    File.binwrite(path, bytes)
    path
  end

  def write_corrupt_archive_key
    path = File.join(@state_root, "archive", "events", "b1", "compacted.json")
    FileUtils.mkdir_p(File.dirname(path))
    event = {
      "schema_version" => 2,
      "event_id" => "archived",
      "batch_id" => "b1",
      "type" => "phase.changed",
      "repo" => "shakacode/example",
      "target" => "42",
      "phase" => "qa",
      "at" => "2026-08-01T00:00:00Z",
      "metadata" => { "corrupt-key" => "value" }
    }
    envelope = {
      "schema_version" => 1,
      "record_family" => "compacted_events",
      "source_paths" => ["events/b1/archived.json"],
      "archived_at" => "2026-08-02T00:00:00Z",
      "delete_after" => "2099-01-01T00:00:00Z",
      "records" => [event]
    }
    bytes = "#{JSON.generate(envelope)}\n".b.sub("corrupt-key".b, "corrupt-\xFF".b)
    File.binwrite(path, bytes)
    path
  end
end

# Events that `gc` compacted into `archive/` are still this work item's custody
# trail (issue #139). Before the archive was read, `log` answered "no events"
# for completed work -- the same words it uses for work that never happened --
# while the history sat intact under `archive/events` on a delete_after clock.
# These tests run the real collector rather than hand-writing an envelope: the
# defect lived in the seam between `gc` and `log`, and a fixture-shaped archive
# would not have caught it.
class AgentCoordLogArchiveTest < AgentCoordLogTestCase
  # Position of event_id in the tsv record, which is the stable way to name the
  # rows a trail reported without depending on rendered column widths.
  TSV_EVENT_ID_COLUMN = 10
  # A lane that ran to completion, which is the shape gc compacts. Compaction
  # keeps the first event, the last event, every terminal event, and actual
  # phase transitions, so e3 -- a release carrying no phase -- is the source
  # event the archive deliberately does not retain.
  CLOSED_LANE_EVENTS = {
    "e1" => { "type" => "claim.acquired", "machine_id" => "m5", "host" => "codex", "agent_id" => "acd-worker",
              "phase" => "implementing", "at" => "2026-08-01T02:40:16Z" },
    "e2" => { "type" => "phase.changed", "machine_id" => "m5", "host" => "codex", "agent_id" => "acd-worker",
              "old_phase" => "implementing", "phase" => "waiting_on_checks_or_review",
              "at" => "2026-08-01T02:45:53Z" },
    "e3" => { "type" => "claim.released", "machine_id" => "m5", "host" => "codex", "agent_id" => "acd-worker",
              "handoff_to" => "maintainer", "at" => "2026-08-01T02:56:53Z" },
    "e4" => { "type" => "claim.acquired", "machine_id" => "m1", "host" => "claude-code",
              "agent_id" => "acd-finisher", "phase" => "final_merge", "at" => "2026-08-01T03:35:49Z" },
    "e5" => { "type" => "lane_closed", "terminal" => "done", "workspace" => "default",
              "closed_by" => { "agent_id" => "acd-finisher", "machine" => "m1" },
              "at" => "2026-08-01T04:00:08Z" }
  }.freeze

  def test_log_reads_a_trail_that_gc_compacted_into_the_archive
    write_closed_lane_trace

    assert_equal %w[e1 e2 e3 e4 e5], tsv_event_ids("shakacode/example#104"), "the live trail before gc"

    compact_events!
    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stdout, "no events", "compacted history is not the absence of history"
    assert_equal retained_event_ids, tsv_event_ids("shakacode/example#104").sort
    assert_includes result.stdout, "lane_closed"
  end

  # Ordering is by instant, not by the prefix an event was read from, so a lane
  # reopened after gc retired its first generation still reads as one history.
  def test_log_interleaves_archived_and_live_events_for_one_work_item
    write_closed_lane_trace
    compact_events!
    write_live_event("e6", "type" => "claim.acquired", "machine_id" => "m2", "host" => "codex",
                           "agent_id" => "acd-reopener", "phase" => "implementing", "at" => "2026-08-01T03:00:00Z")
    write_live_event("e7", "type" => "merged", "machine_id" => "m2", "host" => "codex",
                           "agent_id" => "acd-reopener", "at" => "2026-08-01T05:00:00Z")

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal %w[e1 e2 e6 e4 e5 e7], tsv_rows_event_ids(result)
    assert_includes result.stderr, "4 of 6 events read from the archive"
  end

  # The archive is a supplementary source: reading it may add rows or a warning,
  # and must never turn a trail that reads today into a failure.
  def test_log_degrades_when_the_archive_cannot_be_listed
    write_closed_lane_trace
    compact_events!
    write_live_event("e6", "type" => "merged", "machine_id" => "m2", "host" => "codex",
                           "at" => "2026-08-01T05:00:00Z")
    FileUtils.chmod(0o000, archive_events_directory)

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "archived events unreadable"
    assert_includes result.stderr, "this trail may be incomplete"
    assert_equal %w[e6], tsv_rows_event_ids(result), "the live events must still be reported"
  ensure
    FileUtils.chmod(0o700, archive_events_directory)
  end

  # A short trail reads exactly like a complete one once it is in the mirror,
  # and the mirror is the copy that outlives both compaction and delete_after.
  def test_log_refuses_to_sync_a_trail_whose_archive_could_not_be_read
    write_closed_lane_trace
    compact_events!
    FileUtils.chmod(0o000, archive_events_directory)

    result = run_log("--sync")

    assert_equal 2, result.status.exitstatus
    assert_includes result.stderr, "refusing to sync an incomplete trail: archive/events"
    refute_path_exists File.join(@state_root, "log.tsv")
  ensure
    FileUtils.chmod(0o700, archive_events_directory)
  end

  def test_log_applies_synthetic_filtering_to_archived_events
    write_closed_lane_trace(repo: "sim/race", target: "task_two", batch: "sim", synthetic: true)
    compact_events!("--synthetic-hot-days", "0")

    hidden = run_log("sim/race#task_two")
    shown = run_log("sim/race#task_two", "--include-synthetic")

    assert_includes hidden.stdout, "no events for sim/race#task_two"
    refute_includes hidden.stdout, "claim.acquired"
    assert_includes shown.stdout, "[synthetic]"
    assert_equal retained_event_ids, tsv_event_ids("sim/race#task_two", "--include-synthetic").sort
  end

  # archive/claims and archive/heartbeats hold a different record family whose
  # payload is not an event. Folding one in would report it as an event it never
  # was, so only the archived events prefix is read.
  def test_log_ignores_archived_records_that_are_not_events
    write_claim("shakacode/example", "104", "status" => "released", "agent_id" => "acd-worker",
                                            "machine_id" => "m5", "host" => "codex",
                                            "updated_at" => "2026-08-01T04:00:08Z",
                                            "expires_at" => "2026-08-01T05:00:08Z")
    compact_events!(expect_pruned_events: false)

    result = run_log("shakacode/example#104")

    assert_path_exists File.join(@state_root, "archive", "claims", "shakacode", "example", "104.json")
    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "no events for shakacode/example#104"
    refute_includes result.stdout, "released"
  end

  # Silently skipping an archived record is the bug being fixed, so a family
  # this version does not understand is reported rather than dropped.
  def test_log_reports_an_archived_record_whose_family_it_does_not_know
    write_trace
    write_archive_json("archive/events/b9/compact-future.json",
                       "schema_version" => 1, "record_family" => "compacted_events_v3",
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z")

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "unknown archived record family at archive/events/b9/compact-future.json"
    assert_equal %w[e1 e2 e3 e4 e5], tsv_rows_event_ids(result)
  end

  # Compaction writes the archive envelope before deleting its sources, so a run
  # interrupted between the two leaves one event readable from both places. This
  # is also the duplicate that batch-scoped identity must still collapse: both
  # copies carry the same batch id, so scoping does not weaken it.
  def test_log_reports_an_event_readable_from_both_prefixes_once
    write_closed_lane_trace
    compact_events!
    write_closed_lane_event("e5")

    ids = tsv_event_ids("shakacode/example#104")

    assert_equal ids.uniq, ids
    assert_equal retained_event_ids, ids.sort
  end

  # The mirror deduplicates on the exact tsv line, so this also pins that an
  # archived row renders byte-identically to the live row it replaced.
  def test_log_sync_absorbs_archived_events_without_duplicating_them
    write_closed_lane_trace
    run_log("--sync")
    before = File.readlines(File.join(@state_root, "log.tsv"), encoding: "UTF-8")
    compact_events!

    result = run_log("--sync")
    after = File.readlines(File.join(@state_root, "log.tsv"), encoding: "UTF-8")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "synced 0 new events"
    assert_equal before, after
    assert_equal after.uniq, after
  end

  # The mirror is the only copy that survives delete_after, so an operator who
  # syncs for the first time after gc ran must still get the compacted history.
  def test_log_sync_mirrors_archived_events_into_a_fresh_mirror
    write_closed_lane_trace
    compact_events!

    result = run_log("--sync")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "synced #{retained_event_ids.length} new events"
    mirrored = File.readlines(File.join(@state_root, "log.tsv"), encoding: "UTF-8")

    assert_equal retained_event_ids, mirrored.map { |line| line.split("\t").fetch(TSV_EVENT_ID_COLUMN) }.sort
  end

  # An archived event is the same event it always was, so its row is unchanged
  # and the provenance rides on stderr instead. What the rows cannot show is
  # that part of this history is now on a delete_after clock, and that
  # compaction did not retain every source event it consumed.
  def test_log_notes_archive_provenance_and_the_delete_after_clock
    write_closed_lane_trace
    compact_events!
    envelope = archive_envelopes.fetch(0)
    retained = envelope.fetch("records").length
    dropped = envelope.fetch("source_paths").length - retained

    result = run_log("shakacode/example#104")

    assert_equal 1, dropped, "compaction is lossy, which is the fact this note exists to report"
    assert_includes result.stderr, "note: #{retained} of #{retained} events read from the archive"
    assert_includes result.stderr, "#{dropped} source event was dropped by compaction"
    assert_includes result.stderr, "archive deleted after #{envelope.fetch('delete_after')}"
    assert_includes result.stderr, "mirror it with log --sync"
  end

  def test_log_says_nothing_about_the_archive_for_a_live_trail
    write_trace

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_empty result.stderr
  end

  # One archive record the process cannot open is still an archive read problem,
  # not a reason to stop reporting the live events beside it. The local store
  # reads each record outside the listing's own SystemCallError guard, so this
  # arrived as a bare Errno and emptied the whole trail.
  def test_log_degrades_when_an_archived_record_file_is_unreadable
    write_closed_lane_trace
    compact_events!
    write_live_event("e6", "type" => "merged", "machine_id" => "m2", "host" => "codex",
                           "at" => "2026-08-01T05:00:00Z")
    archive_record_paths.each { |path| FileUtils.chmod(0o000, path) }

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "archived events unreadable"
    assert_includes result.stderr, "this trail may be incomplete"
    refute_includes result.stderr, "SystemCallError", "must not leak the exception class"
    refute_match(%r{\bfrom .*bin/agent-coord:\d+}, result.stderr, "must not leak a Ruby backtrace")
    assert_equal %w[e6], tsv_rows_event_ids(result), "the live events must still be reported"
  ensure
    archive_record_paths.each { |path| FileUtils.chmod(0o600, path) }
  end

  # Truncated JSON already degraded, but valid JSON that is not an object reached
  # the record readers, which assume a Hash. A backend that ships one must not be
  # able to end the command with a raw TypeError.
  def test_log_reports_an_archived_record_that_is_not_an_object
    write_trace
    write_archive_json("archive/events/b9/array.json", [1, 2, 3])

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "unknown archived record family at archive/events/b9/array.json"
    refute_match(/TypeError|no implicit conversion/, result.stderr, "must not leak a raw type error")
    assert_equal %w[e1 e2 e3 e4 e5], tsv_rows_event_ids(result)
  end

  # The note reports the soonest clock, and log_at_key floors an unparseable
  # timestamp to -Infinity -- so one unreadable delete_after would sort first and
  # hide the real date the rest of the archive is deleted on.
  def test_log_reports_the_soonest_parsable_archive_expiry
    write_closed_lane_trace
    compact_events!
    write_archive_json("archive/events/b9/compact-undated.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/x1.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "garbage",
                       "records" => [{ "schema_version" => 2, "event_id" => "x1", "batch_id" => "b9",
                                       "type" => "merged", "repo" => "shakacode/example", "target" => "104",
                                       "machine_id" => "m9", "host" => "codex",
                                       "at" => "2026-08-02T00:00:00Z" }])
    dated = archive_envelopes.map { |envelope| envelope.fetch("delete_after") }.reject { |v| v == "garbage" }

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal 1, dated.length, "exactly one envelope carries a parsable delete_after"
    assert_includes result.stderr, "archive deleted after #{dated.fetch(0)}"
    refute_includes result.stderr, "garbage"
  end

  # event_id is unique within a batch, not across the store: a terminal event
  # takes its id from the lane name alone, so two batches that each register a
  # lane with the same name write the same event_id -- which is what "e5" in two
  # batches is standing in for here. Deduplicating on the bare id let this live
  # record suppress the archived one, and a scoped query for the archived work
  # item answered "no events" while its history sat in the archive.
  def test_log_scopes_deduplication_by_batch_so_one_lane_name_cannot_erase_another
    write_closed_lane_trace
    compact_events!
    write_event("b2", "e5", "type" => "lane_closed", "repo" => "shakacode/other", "target" => "7",
                            "lane" => "lane-a", "terminal" => "done", "workspace" => "default",
                            "closed_by" => { "agent_id" => "other-finisher", "machine" => "m9" },
                            "at" => "2026-08-05T00:00:00Z")

    archived = run_log("shakacode/example#104")

    assert_equal 0, archived.status.exitstatus, archived.stderr
    refute_includes archived.stdout, "no events"
    assert_equal retained_event_ids, tsv_event_ids("shakacode/example#104").sort
    assert_equal %w[e5], tsv_event_ids("shakacode/other#7"), "the live batch keeps its own event"
  end

  # A recognized family with a body this version cannot read used to drop
  # archived history silently, which is the defect the whole archive read exists
  # to remove -- and --sync would then persist the short trail as complete.
  def test_log_reports_a_compacted_envelope_whose_records_are_missing
    write_trace
    write_archive_json("archive/events/b9/compact-bodyless.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/x1.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z")

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "malformed archived record body at archive/events/b9/compact-bodyless.json"
    assert_equal %w[e1 e2 e3 e4 e5], tsv_rows_event_ids(result)
  end

  def test_log_reports_archived_records_it_cannot_read_and_keeps_their_siblings
    write_trace
    write_archive_json("archive/events/b9/compact-mixed.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/x1.json", "events/b9/x2.json", "events/b9/x3.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [{ "schema_version" => 2, "event_id" => "x1", "batch_id" => "b9",
                                       "type" => "merged", "repo" => "shakacode/example", "target" => "104",
                                       "machine_id" => "m9", "host" => "codex",
                                       "at" => "2026-08-06T00:00:00Z" }, 5, "not-an-event"])

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "2 unreadable archived records at archive/events/b9/compact-mixed.json"
    assert_equal %w[e1 e2 e3 e4 e5 x1], tsv_rows_event_ids(result), "the legible sibling is still reported"
    # The envelope retained all three of its sources; two are merely unreadable.
    # Differencing its source count against the records that parsed claimed a
    # loss that had not happened, computed from data just reported as unreadable.
    refute_includes result.stderr, "dropped by compaction"
    assert_includes result.stderr, "compaction loss unknown for 1 unreadable envelope"
  end

  def test_log_reports_an_archived_record_whose_payload_is_not_an_object
    write_trace
    write_archive_json("archive/events/b9/archived-scalar.json",
                       "schema_version" => 1, "record_family" => "archived_record",
                       "source_path" => "events/b9/x1.json", "archived_at" => "2026-08-05T00:00:00Z",
                       "delete_after" => "2026-09-04T00:00:00Z", "data" => "not-an-event")

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "1 unreadable archived record at archive/events/b9/archived-scalar.json"
    assert_equal %w[e1 e2 e3 e4 e5], tsv_rows_event_ids(result)
  end

  # gc retains at least the first and last event of every generation, so an
  # envelope naming consumed source paths while retaining nothing is corruption.
  # Accepting it quietly let --sync exit 0 over a mirror missing those events.
  def test_log_reports_a_compacted_envelope_that_retained_nothing
    write_trace
    write_archive_json("archive/events/b9/compact-empty.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/x1.json", "events/b9/x2.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [])

    result = run_log("shakacode/example#104", "--format", "tsv")
    sync = run_log("--sync")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "no retained records for 2 source paths at archive/events/b9/compact-empty.json"
    assert_equal %w[e1 e2 e3 e4 e5], tsv_rows_event_ids(result)
    assert_equal 2, sync.status.exitstatus, "a mirror must not be written over a corrupt envelope"
    assert_includes sync.stderr, "refusing to sync an incomplete trail: archive/events"
  end

  # Both empty is degenerate but not self-contradictory: the envelope consumed
  # nothing and retained nothing, so there is nothing to report.
  def test_log_accepts_a_compacted_envelope_that_consumed_nothing
    write_trace
    write_archive_json("archive/events/b9/compact-degenerate.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => [], "archived_at" => "2026-08-05T00:00:00Z",
                       "delete_after" => "2026-09-04T00:00:00Z", "records" => [])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stderr, "no retained records"
    assert_equal 0, run_log("--sync").status.exitstatus, "an envelope that consumed nothing is not corruption"
  end

  # event_payload stamps event_id and batch_id together, but that is one
  # producer's behavior rather than a rule the store enforces. A record carrying
  # an id without a batch must not key as [nil, event_id], which would collide
  # across contexts exactly the way the bare id did.
  def test_log_keeps_records_that_carry_an_event_id_without_a_batch
    write_raw_event("b1", "legacy", "schema_version" => 2, "event_id" => "shared",
                                    "type" => "claim.acquired", "repo" => "shakacode/example",
                                    "target" => "104", "machine_id" => "m5", "host" => "codex",
                                    "at" => "2026-08-01T00:00:00Z")
    write_archive_json("archive/events/b2/compact-legacy.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b2/legacy.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [{ "schema_version" => 2, "event_id" => "shared", "type" => "lane_closed",
                                       "repo" => "shakacode/other", "target" => "7", "machine_id" => "m9",
                                       "host" => "codex", "terminal" => "done",
                                       "at" => "2026-08-02T00:00:00Z" }])

    assert_equal %w[shared], tsv_event_ids("shakacode/example#104")
    assert_equal %w[shared], tsv_event_ids("shakacode/other#7"), "the archived record must survive"
  end

  # source_paths is what gc consumed and records is the subset it kept, so an
  # absent or non-array source_paths leaves the note unable to say anything true
  # about compaction loss -- and Array() answered 0 for nil and an arbitrary
  # count for a hash, so it reported no loss at all.
  def test_log_reports_a_compacted_envelope_with_no_source_paths
    write_trace
    write_archive_json("archive/events/b9/compact-sourceless.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [{ "schema_version" => 2, "event_id" => "x1", "batch_id" => "b9",
                                       "type" => "merged", "repo" => "shakacode/example", "target" => "104",
                                       "machine_id" => "m9", "host" => "codex",
                                       "at" => "2026-08-06T00:00:00Z" }])

    result = run_log("shakacode/example#104", "--format", "tsv")
    sync = run_log("--sync")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "malformed archived source paths at archive/events/b9/compact-sourceless.json"
    assert_equal %w[e1 e2 e3 e4 e5 x1], tsv_rows_event_ids(result), "the legible record is still reported"
    assert_equal 2, sync.status.exitstatus, "a mirror must not be written over an unreadable envelope"
  end

  # Compaction keeps a subset of what it consumed, so more retained records than
  # source paths cannot happen and the envelope cannot be trusted to describe
  # its own loss.
  def test_log_reports_a_compacted_envelope_retaining_more_than_it_consumed
    write_trace
    write_archive_json("archive/events/b9/compact-impossible.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/x1.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [{ "schema_version" => 2, "event_id" => "x1", "batch_id" => "b9",
                                       "type" => "merged", "repo" => "shakacode/example", "target" => "104",
                                       "machine_id" => "m9", "host" => "codex",
                                       "at" => "2026-08-06T00:00:00Z" },
                                     { "schema_version" => 2, "event_id" => "x2", "batch_id" => "b9",
                                       "type" => "merged", "repo" => "shakacode/example", "target" => "104",
                                       "machine_id" => "m9", "host" => "codex",
                                       "at" => "2026-08-07T00:00:00Z" }])

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr,
                    "2 retained records exceed 1 source path at archive/events/b9/compact-impossible.json"
    assert_equal %w[e1 e2 e3 e4 e5 x1 x2], tsv_rows_event_ids(result), "legible records are still reported"
  end

  # A compaction interrupted between writing its envelope and deleting its
  # sources leaves every retained record readable from both prefixes. The live
  # copies win the rows, so the envelope contributed none -- and its
  # delete_after clock and dropped-source count fell out of the note entirely.
  def test_log_reports_archive_provenance_when_every_record_is_also_live
    write_closed_lane_trace
    compact_events!
    CLOSED_LANE_EVENTS.each_key { |event_id| write_closed_lane_event(event_id) }
    envelope = archive_envelopes.fetch(0)

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal %w[e1 e2 e3 e4 e5], tsv_event_ids("shakacode/example#104"), "the live copies are reported"
    assert_includes result.stderr, "note: 4 of 5 events are also held in the archive"
    assert_includes result.stderr, "1 source event was dropped by compaction"
    assert_includes result.stderr, "archive deleted after #{envelope.fetch('delete_after')}"
  end

  # gc writes an envelope before deleting its sources, so a run interrupted part
  # way leaves the next one compacting the remainder into a second envelope, and
  # both can name the same omitted source event. Differencing each envelope and
  # summing reported that one lost event as two, and which number you got
  # depended on the order the listing yielded the envelopes in.
  def test_log_counts_a_source_dropped_by_two_overlapping_envelopes_once
    write_archive_json("archive/events/b9/compact-first.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/e1.json", "events/b9/e2.json", "events/b9/e3.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("e1", "2026-08-01T00:00:00Z"),
                                     overlap_event("e3", "2026-08-03T00:00:00Z")])
    write_archive_json("archive/events/b9/compact-second.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/e2.json", "events/b9/e4.json"],
                       "archived_at" => "2026-08-06T00:00:00Z", "delete_after" => "2026-09-05T00:00:00Z",
                       "records" => [overlap_event("e4", "2026-08-04T00:00:00Z")])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal %w[e1 e3 e4], tsv_event_ids("shakacode/example#104")
    assert_includes result.stderr, "1 source event was dropped by compaction"
    refute_includes result.stderr, "2 source events were dropped by compaction"
  end

  # The envelope's own synthetic flag is false, so gc consumed a real event, and
  # its source count proves one was not retained. The default filter removes the
  # only surviving row, but the loss it records is still real -- and the note was
  # computed from surviving rows, so it vanished along with them.
  def test_log_reports_a_mixed_envelope_whose_surviving_rows_are_all_synthetic
    write_archive_json("archive/events/b9/compact-mixed-synthetic.json",
                       "schema_version" => 1, "record_family" => "compacted_events", "synthetic" => false,
                       "source_paths" => ["events/b9/s1.json", "events/b9/e2.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("s1", "2026-08-01T00:00:00Z").merge("synthetic" => true)])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "no events for shakacode/example#104"
    assert_includes result.stderr, "note: the archive holds a compacted record for this trail"
    assert_includes result.stderr, "1 source event was dropped by compaction"
    assert_includes result.stderr, "archive deleted after 2026-09-04T00:00:00Z"
  end

  # An interrupted compaction can leave a second envelope whose every identity
  # the first already claimed. It contributes no row, and the note used to read
  # its facts off rows, so its clock and its consumed sources disappeared.
  def test_log_reports_an_overlapping_envelope_that_contributed_no_row
    write_archive_json("archive/events/b9/compact-a.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/e1.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-30T00:00:00Z",
                       "records" => [overlap_event("e1", "2026-08-01T00:00:00Z")])
    write_archive_json("archive/events/b9/compact-b.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/e1.json", "events/b9/e2.json"],
                       "archived_at" => "2026-08-06T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("e1", "2026-08-01T00:00:00Z")])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal %w[e1], tsv_event_ids("shakacode/example#104")
    # The second envelope's earlier clock, and the source only it names.
    assert_includes result.stderr, "archive deleted after 2026-09-04T00:00:00Z"
    assert_includes result.stderr, "1 source event was dropped by compaction"
  end

  # A live event whose archived duplicate was skipped is on the same clock as one
  # read from the archive. Counting only what was read directly said "1 of 3"
  # while two more were expiring unmentioned.
  def test_log_counts_live_events_that_are_also_held_in_the_archive
    write_event("b1", "e1", "type" => "claim.acquired", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m5", "host" => "codex", "at" => "2026-08-01T00:00:00Z")
    write_event("b1", "e2", "type" => "phase.changed", "repo" => "shakacode/example", "target" => "104",
                            "machine_id" => "m5", "host" => "codex", "at" => "2026-08-02T00:00:00Z")
    write_archive_json("archive/events/b1/compact-held.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b1/e1.json", "events/b1/e2.json", "events/b1/e3.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("e1", "2026-08-01T00:00:00Z").merge("batch_id" => "b1"),
                                     overlap_event("e2", "2026-08-02T00:00:00Z").merge("batch_id" => "b1"),
                                     overlap_event("e3", "2026-08-03T00:00:00Z").merge("batch_id" => "b1")])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal %w[e1 e2 e3], tsv_event_ids("shakacode/example#104")
    assert_includes result.stderr, "note: 1 of 3 events read from the archive"
    assert_includes result.stderr, "2 more held there too"
  end

  # --limit trims what is shown, never the evidence that decides a question. The
  # note is evidence: this item's history is compacted and expiring however few
  # of its rows the caller asked to see.
  def test_log_reports_the_archive_clock_under_limit_and_since
    write_closed_lane_trace
    compact_events!
    write_live_event("e9", "type" => "merged", "machine_id" => "m2", "host" => "codex",
                           "at" => "2026-08-09T00:00:00Z")
    envelope = archive_envelopes.fetch(0)

    limited = run_log("shakacode/example#104", "--limit", "1")
    since = run_log("shakacode/example#104", "--since", "2026-08-05T00:00:00Z")

    assert_equal 1, limited.stdout.lines.length, "only the newest row is displayed"
    assert_includes limited.stderr, "archive deleted after #{envelope.fetch('delete_after')}"
    assert_includes limited.stderr, "1 source event was dropped by compaction"
    assert_includes since.stderr, "archive deleted after #{envelope.fetch('delete_after')}"
  end

  # archived_record names its one consumed path as a singular source_path. The
  # ledger counted no sources for it while still counting its identity as
  # retained, so the extra identity cancelled a genuinely dropped compacted
  # source and the note reported none.
  def test_log_counts_the_singular_source_of_an_archived_record
    write_archive_json("archive/events/b9/compact-two.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/e1.json", "events/b9/e2.json", "events/b9/e3.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("e1", "2026-08-01T00:00:00Z"),
                                     overlap_event("e3", "2026-08-03T00:00:00Z")])
    write_archive_json("archive/events/b9/archived-one.json",
                       "schema_version" => 1, "record_family" => "archived_record",
                       "source_path" => "events/b9/e4.json", "archived_at" => "2026-08-05T00:00:00Z",
                       "delete_after" => "2026-09-04T00:00:00Z",
                       "data" => overlap_event("e4", "2026-08-04T00:00:00Z"))

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal %w[e1 e3 e4], tsv_event_ids("shakacode/example#104")
    assert_includes result.stderr, "1 source event was dropped by compaction"
  end

  # The archive read and the work-item identity folding (PR #145) meet here: an
  # envelope recorded under issue:104 belongs to the same work item as a bare
  # #104 query, so the note must scope it in. Matching the recorded spelling
  # instead would have hidden the clock on exactly the trails #145 unified.
  def test_log_scopes_archived_envelopes_through_work_item_identity
    write_archive_json("archive/events/b9/compact-spelled.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/e1.json", "events/b9/e2.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("e1", "2026-08-01T00:00:00Z").merge("target" => "issue:104")])

    bare = run_log("shakacode/example#104")
    lane = run_log("shakacode/example#issue:104")

    assert_equal 0, bare.status.exitstatus, bare.stderr
    assert_includes bare.stdout, "issue:104", "the bare query covers the spelled target"
    assert_includes bare.stderr, "archive deleted after 2026-09-04T00:00:00Z"
    assert_includes bare.stderr, "1 source event was dropped by compaction"
    assert_includes lane.stderr, "archive deleted after 2026-09-04T00:00:00Z"
  end

  # A different work item's envelope must stay out of the note, however the
  # queried item was spelled.
  def test_log_keeps_another_work_items_envelope_out_of_the_note
    write_archive_json("archive/events/b9/compact-other.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/x1.json", "events/b9/x2.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("x1", "2026-08-01T00:00:00Z").merge("target" => "999")])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stderr, "archive deleted after"
    refute_includes result.stderr, "dropped by compaction"
  end

  # A source list is what the dropped-source arithmetic counts, so an entry that
  # is not a path, or the same path twice, cannot be counted. Left unvalidated,
  # a retained record cancelled a source that really was omitted.
  def test_log_reports_a_compacted_envelope_whose_source_paths_are_not_paths
    write_trace
    write_archive_json("archive/events/b9/compact-nilsource.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/e1.json", nil, ""],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("e1", "2026-08-01T00:00:00Z")])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr,
                    "malformed archived source paths at archive/events/b9/compact-nilsource.json"
    refute_includes result.stderr, "dropped by compaction"
    assert_equal 2, run_log("--sync").status.exitstatus, "a mirror must not be written over it"
  end

  def test_log_reports_a_compacted_envelope_with_duplicate_source_paths
    write_trace
    write_archive_json("archive/events/b9/compact-dupsource.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/e1.json", "events/b9/e1.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("e1", "2026-08-01T00:00:00Z")])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr,
                    "duplicate archived source paths at archive/events/b9/compact-dupsource.json"
    refute_includes result.stderr, "dropped by compaction"
  end

  # archived_record names one consumed path. Without one the note cannot say what
  # the entry consumed, and silently treating that as zero let its retained
  # identity cancel a genuine loss elsewhere in scope.
  def test_log_reports_an_archived_record_without_a_source_path
    write_trace
    write_archive_json("archive/events/b9/archived-sourceless.json",
                       "schema_version" => 1, "record_family" => "archived_record",
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "data" => overlap_event("e9", "2026-08-09T00:00:00Z"))

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr,
                    "malformed archived source paths at archive/events/b9/archived-sourceless.json"
    refute_includes tsv_rows_event_ids(result), "e9", "an entry that cannot be counted is not folded in"
  end

  # Over HTTP the record path is whatever the backend put in its listing, so it
  # reaches the terminal only after scrubbing -- an archive record is not a
  # trusted source of escape sequences.
  def test_log_scrubs_control_characters_out_of_an_archive_warning
    write_trace
    write_archive_json("archive/events/b9/compact-\e[31mred.json",
                       "schema_version" => 1, "record_family" => "future_family",
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z")

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "unknown archived record family"
    refute_includes result.stderr, "\e", "an escape sequence must not reach the terminal"
    assert_equal %w[e1 e2 e3 e4 e5], tsv_rows_event_ids(result)
  end

  def test_log_scrubs_control_characters_out_of_an_unreadable_archive_warning
    write_trace
    path = "archive/events/b9/compact-\e[31mred.json"
    write_archive_json(path, "schema_version" => 1, "record_family" => "compacted_events", "records" => [])
    FileUtils.chmod(0o000, File.join(@state_root, path))

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "archived events unreadable"
    refute_includes result.stderr, "\e", "an escape sequence must not reach the terminal"
    assert_equal %w[e1 e2 e3 e4 e5], tsv_rows_event_ids(result)
  ensure
    archive_record_paths.each { |file| FileUtils.chmod(0o600, file) }
  end

  # An envelope none of whose records parse still exists and is still expiring.
  # Skipping ledger registration when nothing legible came out of it took its
  # delete_after out of the note with its rows. The query is unscoped here
  # deliberately: with no legible record there is no work item to scope by, so a
  # scoped query cannot claim it -- that is a limit of the data, not of the note.
  def test_log_reports_the_clock_of_an_envelope_whose_records_are_all_unreadable
    write_trace
    write_archive_json("archive/events/b9/compact-illegible.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/x1.json", "events/b9/x2.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [5, "not-an-event"])

    result = run_log

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "2 unreadable archived records at archive/events/b9/compact-illegible.json"
    assert_includes result.stderr, "note: the archive holds a compacted record for this trail"
    assert_includes result.stderr, "archive deleted after 2026-09-04T00:00:00Z"
    assert_includes result.stderr, "compaction loss unknown for 1 unreadable envelope"
    refute_includes result.stderr, "dropped by compaction"
  end

  # Comparing the raw array called a mixed envelope impossible when what actually
  # happened was that two of its three records were unreadable. The operator
  # debugging a corrupt archive needs the second diagnosis, not the first.
  def test_log_diagnoses_unreadable_records_rather_than_an_impossible_count
    write_trace
    write_archive_json("archive/events/b9/compact-miscounted.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/x1.json", "events/b9/x2.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("x1", "2026-08-06T00:00:00Z"), 5, "not-an-event"])

    result = run_log("shakacode/example#104", "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "2 unreadable archived records at archive/events/b9/compact-miscounted.json"
    refute_includes result.stderr, "retained records exceed"
    assert_equal %w[e1 e2 e3 e4 e5 x1], tsv_rows_event_ids(result), "the legible record is still reported"
  end

  # Rows read each record's own synthetic flag, so a real record inside an
  # envelope gc marked synthetic is reported. Scoping the ledger by the envelope
  # flag instead dropped that row's provenance, so it printed with no retention
  # or expiry note and --sync took the trail as complete. The mirror image of
  # test_log_reports_a_mixed_envelope_whose_surviving_rows_are_all_synthetic:
  # either flag alone still leaves real information in the envelope.
  def test_log_reports_a_real_record_inside_a_synthetic_envelope
    write_archive_json("archive/events/b9/compact-synthetic-envelope.json",
                       "schema_version" => 1, "record_family" => "compacted_events", "synthetic" => true,
                       "source_paths" => ["events/b9/e1.json", "events/b9/e2.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("e1", "2026-08-01T00:00:00Z")])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal %w[e1], tsv_event_ids("shakacode/example#104"), "the real record is reported"
    assert_includes result.stderr, "1 source event was dropped by compaction"
    assert_includes result.stderr, "archive deleted after 2026-09-04T00:00:00Z"
  end

  # A wholly synthetic envelope is still hidden: both measures agree on it.
  def test_log_hides_an_envelope_synthetic_by_both_measures
    write_archive_json("archive/events/b9/compact-all-synthetic.json",
                       "schema_version" => 1, "record_family" => "compacted_events", "synthetic" => true,
                       "source_paths" => ["events/b9/s1.json", "events/b9/s2.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "2026-09-04T00:00:00Z",
                       "records" => [overlap_event("s1", "2026-08-01T00:00:00Z").merge("synthetic" => true)])

    result = run_log("shakacode/example#104")

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stderr, "archive deleted after"
    refute_includes result.stderr, "dropped by compaction"
  end

  # The retention clock is the one warning that says this history is going to
  # disappear. Filtering an unreadable one out of the comparison and saying
  # nothing left the trail reading complete while it expired, and --sync
  # accepted it. The records beside it are still reported: a bad clock says
  # nothing about whether they can be read.
  def test_log_reports_an_envelope_whose_expiry_cannot_be_read
    write_archive_json("archive/events/b9/compact-undated.json",
                       "schema_version" => 1, "record_family" => "compacted_events",
                       "source_paths" => ["events/b9/e1.json", "events/b9/e2.json"],
                       "archived_at" => "2026-08-05T00:00:00Z", "delete_after" => "whenever",
                       "records" => [overlap_event("e1", "2026-08-01T00:00:00Z")])

    result = run_log("shakacode/example#104")
    sync = run_log("--sync")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stderr, "unreadable archive expiry at archive/events/b9/compact-undated.json"
    assert_equal %w[e1], tsv_event_ids("shakacode/example#104"), "its records are still reported"
    assert_includes result.stderr, "1 source event was dropped by compaction"
    refute_includes result.stderr, "archive deleted after"
    assert_equal 2, sync.status.exitstatus, "a mirror must not be written over an unreadable clock"
  end

  private

  def overlap_event(event_id, at)
    { "schema_version" => 2, "event_id" => event_id, "batch_id" => "b9", "type" => "merged",
      "repo" => "shakacode/example", "target" => "104", "machine_id" => "m9", "host" => "codex", "at" => at }
  end

  # Written verbatim, because write_event always stamps a batch_id and these
  # fixtures exist to exercise a record that carries none.
  def write_raw_event(batch_id, name, record)
    path = File.join(@state_root, "events", batch_id, "#{name}.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.generate(record)}\n")
  end

  def write_closed_lane_trace(repo: "shakacode/example", target: "104", batch: "b1", synthetic: false)
    @lane_identity = { repo: repo, target: target, batch: batch, synthetic: synthetic }
    CLOSED_LANE_EVENTS.each_key { |event_id| write_closed_lane_event(event_id) }
  end

  def write_closed_lane_event(event_id)
    payload = CLOSED_LANE_EVENTS.fetch(event_id).merge(
      "repo" => @lane_identity.fetch(:repo), "target" => @lane_identity.fetch(:target), "lane" => "lane-a"
    )
    payload = payload.merge("synthetic" => true, "synthetic_kind" => "simulation") if @lane_identity.fetch(:synthetic)
    write_event(@lane_identity.fetch(:batch), event_id, payload)
  end

  # A live event for the same work item, recorded into a later batch so it is
  # not swept into the generation gc already retired.
  def write_live_event(event_id, payload)
    write_event("b2", event_id,
                payload.merge("repo" => @lane_identity.fetch(:repo), "target" => @lane_identity.fetch(:target)))
  end

  # --hot-days 0 retires the generation immediately; everything else is the
  # collector operators actually run.
  def compact_events!(*flags, expect_pruned_events: true)
    result = run_command(COMMAND_ENV.merge("AGENT_COORD_STATE_ROOT" => @state_root),
                         "ruby", BIN, "gc", "--execute", "--hot-days", "0", *flags)

    assert_equal 0, result.status.exitstatus, result.stderr
    if expect_pruned_events
      assert_empty Dir.glob(File.join(@state_root, "events", "**", "*.json")),
                   "gc must have pruned the hot events for this fixture"
    end
    result
  end

  def archive_events_directory
    File.join(@state_root, "archive", "events")
  end

  def archive_record_paths
    Dir.glob(File.join(archive_events_directory, "**", "*.json"))
  end

  def archive_envelopes
    archive_record_paths.map { |path| JSON.parse(File.read(path)) }
  end

  def retained_event_ids
    archive_envelopes.flat_map { |envelope| envelope.fetch("records").map { |record| record.fetch("event_id") } }.sort
  end

  def write_archive_json(path, data)
    file = File.join(@state_root, path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "#{JSON.generate(data)}\n")
  end

  def tsv_event_ids(*)
    result = run_log(*, "--format", "tsv")

    assert_equal 0, result.status.exitstatus, result.stderr
    tsv_rows_event_ids(result)
  end

  def tsv_rows_event_ids(result)
    result.stdout.lines.map { |line| line.split("\t").fetch(TSV_EVENT_ID_COLUMN) }
  end
end
