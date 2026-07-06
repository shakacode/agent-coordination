# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SIM_ROOT = File.expand_path("..", __dir__) unless defined?(SIM_ROOT)
WORKER = File.join(SIM_ROOT, "bin", "scripted-worker") unless defined?(WORKER)

class ScriptedWorkerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @state = File.join(@dir, "state")
    Dir.mkdir(@state)
    @origin = File.join(@dir, "origin.git")
    system("git", "init", "-q", "--bare", @origin, exception: true)
    seed = File.join(@dir, "seed")
    FileUtils.cp_r(File.join(SIM_ROOT, "template", "."), seed)
    Dir.chdir(seed) do
      system("git init -q -b main && " \
             "git config user.name 'agent-coord sim test' && " \
             "git config user.email 'agent-coord-sim@example.invalid' && " \
             "git add -A && git commit -qm seed && " \
             "git remote add origin #{@origin} && git push -q origin main", exception: true)
    end
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_worker(agent_id, issue_key: "task_one", clone_url: @origin)
    env = { "AGENT_COORD_STATE_ROOT" => @state }
    Open3.capture3(
      env, WORKER,
      "--agent-id", agent_id, "--repo-slug", "sim/local",
      "--clone-url", clone_url, "--issue-key", issue_key,
      "--workdir", File.join(@dir, "work-#{agent_id}")
    )
  end

  def test_worker_completes_and_records_protocol
    stdout, stderr, status = run_worker("host:worker")
    assert_equal 0, status.exitstatus, "worker failed: #{stderr}"
    assert_includes stdout, "WORKER_DONE"

    claim = JSON.parse(File.read(File.join(@state, "claims", "sim", "local", "task_one.json")))
    assert_equal "released", claim.fetch("status")
    heartbeat = JSON.parse(File.read(File.join(@state, "heartbeats", "host:worker.json")))
    assert_equal "done", heartbeat.fetch("status")

    branches = `git --git-dir=#{@origin} branch --list`.lines.map(&:strip)
    assert_includes branches, "sim/task_one-host-worker"
  end

  def test_second_worker_is_refused_while_first_holds_claim
    env = { "AGENT_COORD_STATE_ROOT" => @state }
    system(
      env, File.expand_path("../../bin/agent-coord", __dir__),
      "claim", "--agent-id", "holder", "--repo", "sim/local",
      "--target", "task_one", exception: true, out: File::NULL
    )
    system(env, File.expand_path("../../bin/agent-coord", __dir__),
           "heartbeat", "--agent-id", "holder", exception: true, out: File::NULL)

    stdout, _stderr, status = run_worker("w2")
    assert_equal 3, status.exitstatus
    assert_includes stdout, "WORKER_REFUSED"
  end

  def test_unknown_issue_key_fails_before_claim
    stdout, _stderr, status = run_worker("w3", issue_key: "task_four")
    assert_equal 2, status.exitstatus
    assert_includes stdout, "unknown issue key: task_four"
    refute File.exist?(File.join(@state, "claims", "sim", "local", "task_four.json"))
  end

  def test_failure_after_claim_releases_claim
    missing_origin = File.join(@dir, "missing.git")
    _stdout, _stderr, status = run_worker("w4", clone_url: missing_origin)
    assert_equal 2, status.exitstatus

    claim = JSON.parse(File.read(File.join(@state, "claims", "sim", "local", "task_one.json")))
    assert_equal "released", claim.fetch("status")
    heartbeat = JSON.parse(File.read(File.join(@state, "heartbeats", "w4.json")))
    assert_equal "failed", heartbeat.fetch("status")
  end
end
