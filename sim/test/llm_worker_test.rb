# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class LlmWorkerTest < Minitest::Test
  LLM_WORKER = File.expand_path("../bin/llm-worker", __dir__)

  def test_codex_prompt_claims_manifest_key_with_branch
    with_fake_tools do |env, prompt_path|
      stdout, stderr, status = Open3.capture3(
        env, LLM_WORKER, "codex", "shakacode/agent-coord-sim-alpha", "7", "batch-42"
      )
      assert_equal 0, status.exitstatus, stderr

      prompt = File.read(prompt_path)
      branch = "sim/task_one-sim-codex-batch-42-task_one"
      assert_includes prompt, "Issue key: task_one"
      assert_includes prompt, "--target task_one --batch-id batch-42 --branch #{branch}"
      assert_includes prompt, "create branch `#{branch}`"
      assert_includes prompt, "--target task_one --branch #{branch}"
      assert_includes stdout, "LLM_WORKER_EXIT host=codex issue=7 issue_key=task_one"
      assert_includes stdout, "exit=0"
      cleanup_workdir(stdout)
    end
  end

  def test_codex_failure_still_prints_workdir_trailer
    with_fake_tools(codex_exit: 17) do |env, _prompt_path|
      stdout, _stderr, status = Open3.capture3(
        env, LLM_WORKER, "codex", "shakacode/agent-coord-sim-alpha", "7", "batch-42"
      )
      assert_equal 17, status.exitstatus
      assert_includes stdout, "LLM_WORKER_EXIT host=codex issue=7 issue_key=task_one"
      assert_includes stdout, "workdir="
      assert_includes stdout, "exit=17"
      cleanup_workdir(stdout)
    end
  end

  private

  def with_fake_tools(codex_exit: 0)
    Dir.mktmpdir do |dir|
      prompt_path = File.join(dir, "prompt.md")
      write_fake_gh(File.join(dir, "gh"))
      write_fake_codex(File.join(dir, "codex"))
      env = {
        "PATH" => "#{dir}:#{ENV.fetch('PATH')}",
        "GH_BIN" => File.join(dir, "gh"),
        "CODEX_BIN" => File.join(dir, "codex"),
        "PROMPT_OUT" => prompt_path,
        "CODEX_EXIT" => codex_exit.to_s
      }
      yield env, prompt_path
    end
  end

  def write_fake_gh(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby

      if ARGV[0, 2] == ["issue", "view"]
        puts "positive_sum must exclude negative numbers"
      else
        warn "unexpected gh args: #{ARGV.join(' ')}"
        exit 2
      end
    RUBY
    FileUtils.chmod(0o755, path)
  end

  def write_fake_codex(path)
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby

      File.write(ENV.fetch("PROMPT_OUT"), ARGV.fetch(-1))
      exit ENV.fetch("CODEX_EXIT", "0").to_i
    RUBY
    FileUtils.chmod(0o755, path)
  end

  def cleanup_workdir(stdout)
    workdir = stdout[/workdir=(\S+)/, 1]
    FileUtils.remove_entry(workdir) if workdir && Dir.exist?(workdir)
  end
end
