# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "time"
require "tmpdir"

class HostLimitCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "agent-coord")

  def setup
    @state_root = Dir.mktmpdir("agent-coord-host-limit")
    @config_home = Dir.mktmpdir("agent-coord-host-limit-config")
  end

  def teardown
    FileUtils.remove_entry(@state_root)
    FileUtils.remove_entry(@config_home)
  end

  def test_report_creates_manual_unknown_reset_record_at_encoded_workspace_key
    result = run_cli(
      "report-host-limit",
      "--workspace", "team/東京",
      "--machine", "mac%/é",
      "--quota-host", " Quota-Host-A ",
      "--scope", "five-hour",
      "--json"
    )

    assert_success result
    record = JSON.parse(result.stdout).fetch("record")
    assert_equal(
      {
        "schema_version" => 1,
        "workspace" => "team/東京",
        "machine" => "mac%/é",
        "quota_host" => "quota-host-a",
        "scope" => "five-hour",
        "status" => "active",
        "observed_at" => record.fetch("observed_at"),
        "resets_at" => nil,
        "source" => "manual"
      },
      record
    )
    path = File.join(
      @state_root,
      "host_limits/team%2F%E6%9D%B1%E4%BA%AC/mac%25%2F%C3%A9/quota-host-a/five-hour.json"
    )
    assert_equal record, JSON.parse(File.read(path))
  end

  def test_status_shows_every_record_field_and_marks_ineffective_records
    write_host_limit("five-hour", "active", "2999-01-01T00:00:00Z")
    write_host_limit("weekly", "active", nil)
    write_host_limit("elapsed", "active", "2000-01-01T00:00:00Z")
    write_host_limit("cleared", "cleared", nil, "2026-01-02T00:00:00Z")

    json = run_cli("status", "--json")

    assert_success json
    records = JSON.parse(json.stdout).fetch("host_limits")
    assert_equal(%w[cleared elapsed five-hour weekly], records.map { |record| record.fetch("scope") })
    assert(records.all? { |record| (host_limit_record_keys - record.keys).empty? })
    assert_equal "2026-01-02T00:00:00Z", records.first.fetch("cleared_at")

    text = run_cli("status")
    assert_success text
    assert_includes text.stdout, "host_limits\n"
    assert_includes text.stdout,
                    "schema_version 1 workspace default machine build-mac-01 quota_host quota-host-a " \
                    "scope five-hour status active effective true observed_at 2026-01-01T00:00:00Z " \
                    "resets_at 2999-01-01T00:00:00Z source manual"
    assert_includes text.stdout, "scope weekly status active effective true"
    assert_includes text.stdout, "scope elapsed status active effective false"
    assert_includes text.stdout,
                    "scope cleared status cleared effective false observed_at 2026-01-01T00:00:00Z " \
                    "resets_at unknown source manual cleared_at 2026-01-02T00:00:00Z"
  end

  def test_clear_preserves_observation_and_report_reactivates_same_record
    write_host_limit("weekly", "active", nil)

    cleared = run_cli(
      "clear-host-limit", "--workspace", "default", "--machine", "build-mac-01",
      "--quota-host", "quota-host-a", "--scope", "weekly", "--json"
    )

    assert_success cleared
    cleared_record = JSON.parse(cleared.stdout).fetch("record")
    assert_equal "cleared", cleared_record.fetch("status")
    assert_operator Time.iso8601(cleared_record.fetch("cleared_at")), :>=,
                    Time.iso8601(cleared_record.fetch("observed_at"))
    status_record = JSON.parse(run_cli("status", "--json").stdout).fetch("host_limits").fetch(0)
    assert_equal "cleared", status_record.fetch("status")
    assert_equal cleared_record.fetch("cleared_at"), status_record.fetch("cleared_at")

    reported = run_cli(
      "report-host-limit", "--workspace", "default", "--machine", "build-mac-01",
      "--quota-host", "quota-host-a", "--scope", "weekly",
      "--resets-at", "2999-01-01T00:00:00-05:00", "--json"
    )

    assert_success reported
    active = JSON.parse(reported.stdout).fetch("record")
    assert_equal "active", active.fetch("status")
    assert_equal "2026-01-01T00:00:00Z", active.fetch("observed_at")
    assert_equal "2999-01-01T05:00:00Z", active.fetch("resets_at")
    refute active.key?("cleared_at")
  end

  def test_clear_refuses_to_write_a_timestamp_before_the_observation
    record = {
      "schema_version" => 1, "workspace" => "default", "machine" => "build-mac-01",
      "quota_host" => "quota-host-a", "scope" => "weekly", "status" => "active",
      "observed_at" => "2999-01-01T00:00:00Z", "resets_at" => nil, "source" => "manual"
    }
    write_record(record)

    result = run_cli(
      "clear-host-limit", "--machine", "build-mac-01", "--quota-host", "quota-host-a", "--scope", "weekly"
    )

    assert_equal 2, result.status.exitstatus
    assert_includes result.stderr, "cannot clear host-limit record before observed_at"
    assert_equal "active", JSON.parse(File.read(host_limit_file("weekly"))).fetch("status")
  end

  def test_gc_archives_only_cleared_records_using_cleared_at
    write_host_limit("cleared", "cleared", nil, "2026-01-02T00:00:00Z")
    write_host_limit("elapsed", "active", "2000-01-01T00:00:00Z")
    write_host_limit("unknown", "active", nil)

    dry_run = run_cli("gc", "--dry-run", "--hot-days", "0", "--prefix", "host_limits", "--json")

    assert_success dry_run
    actions = JSON.parse(dry_run.stdout).fetch("actions")
    assert_equal 1, actions.length
    assert_equal "cleared_host_limit", actions.first.fetch("reason")
    assert_equal "2026-01-02T00:00:00Z", actions.first.fetch("eligible_at")
    assert File.file?(host_limit_file("cleared"))

    execute = run_cli("gc", "--execute", "--hot-days", "0", "--prefix", "host_limits", "--json")

    assert_success execute
    refute File.exist?(host_limit_file("cleared"))
    assert File.file?(File.join(@state_root, "archive", host_limit_relative_path("cleared")))
    assert File.file?(host_limit_file("elapsed"))
    assert File.file?(host_limit_file("unknown"))
  end

  def test_shipped_replay_projects_one_shared_limit_for_both_lanes
    replay_path = File.join(ROOT, "schema", "state", "v1", "fixtures", "replay", "two-lanes-one-host-limit.json")
    replay = JSON.parse(File.read(replay_path))
    record = replay.dig("status", "host_limits").fetch(0)
    write_record(record)

    status = run_cli("status", "--json")

    assert_success status
    effective = JSON.parse(status.stdout).fetch("host_limits")
    lane_statuses = replay.fetch("lanes").to_h do |lane|
      blocked = effective.any? do |limit|
        %w[workspace machine quota_host].all? { |field| lane.fetch(field) == limit.fetch(field) }
      end
      [lane.fetch("lane"), blocked ? "blocked-on-limit" : "available"]
    end
    assert_equal 1, effective.length
    assert_equal replay.dig("expected", "lane_statuses"), lane_statuses
    assert(replay.fetch("lanes").all? { |lane| lane.fetch("host") != lane.fetch("quota_host") })
  end

  private

  def run_cli(*)
    env = {
      "AGENT_COORD_API_TOKEN" => nil,
      "AGENT_COORD_API_URL" => nil,
      "AGENT_COORD_BACKEND" => nil,
      "AGENT_COORD_ENV_FILE" => nil,
      "AGENT_COORD_LOCAL" => "1",
      "AGENT_COORD_STATE_ROOT" => nil,
      "XDG_CONFIG_HOME" => @config_home
    }
    stdout, stderr, status = Open3.capture3(env, BIN, *, "--state-root", @state_root)
    Struct.new(:stdout, :stderr, :status).new(stdout, stderr, status)
  end

  def write_host_limit(scope, status, resets_at, cleared_at = nil)
    record = {
      "schema_version" => 1,
      "workspace" => "default",
      "machine" => "build-mac-01",
      "quota_host" => "quota-host-a",
      "scope" => scope,
      "status" => status,
      "observed_at" => "2026-01-01T00:00:00Z",
      "resets_at" => resets_at,
      "source" => "manual"
    }
    record["cleared_at"] = cleared_at if cleared_at
    write_record(record)
  end

  def write_record(record)
    path = File.join(
      @state_root, "host_limits", encode_component(record.fetch("workspace")),
      encode_component(record.fetch("machine")), record.fetch("quota_host"), "#{record.fetch('scope')}.json"
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(record)}\n")
  end

  def encode_component(value)
    value.encode(Encoding::UTF_8).bytes.map do |byte|
      if byte.between?(48, 57) || byte.between?(65, 90) || byte.between?(97, 122) || [45, 95].include?(byte)
        byte.chr
      else
        format("%%%02X", byte)
      end
    end.join
  end

  def host_limit_relative_path(scope)
    File.join("host_limits", "default", "build-mac-01", "quota-host-a", "#{scope}.json")
  end

  def host_limit_file(scope)
    File.join(@state_root, host_limit_relative_path(scope))
  end

  def host_limit_record_keys
    %w[schema_version workspace machine quota_host scope status observed_at resets_at source]
  end

  def assert_success(result)
    assert_equal 0, result.status.exitstatus, result.stderr
  end
end
