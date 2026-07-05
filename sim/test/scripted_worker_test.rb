# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SIM_ROOT = File.expand_path("..", __dir__)
WORKER = File.join(SIM_ROOT, "bin", "scripted-worker")

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

  def run_worker(agent_id)
    env = { "AGENT_COORD_STATE_ROOT" => @state }
    Open3.capture3(
      env, WORKER,
      "--agent-id", agent_id, "--repo-slug", "sim/local",
      "--clone-url", @origin, "--issue-key", "task_one",
      "--workdir", File.join(@dir, "work-#{agent_id}")
    )
  end

  def test_worker_completes_and_records_protocol
    stdout, stderr, status = run_worker("w1")
    assert_equal 0, status.exitstatus, "worker failed: #{stderr}"
    assert_includes stdout, "WORKER_DONE"

    claim = JSON.parse(File.read(File.join(@state, "claims", "sim", "local", "task_one.json")))
    assert_equal "released", claim.fetch("status")
    heartbeat = JSON.parse(File.read(File.join(@state, "heartbeats", "w1.json")))
    assert_equal "done", heartbeat.fetch("status")

    branches = `git --git-dir=#{@origin} branch --list`.lines.map(&:strip)
    assert_includes branches, "sim/task_one-w1"
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
end
