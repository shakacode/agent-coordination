# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class LlmWorkerTest < Minitest::Test
  LLM_WORKER = File.expand_path("../bin/llm-worker", __dir__)
  WORKER_PROMPT = File.expand_path("../prompts/worker-prompt.md", __dir__)

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

  def test_non_ascii_manifest_title_is_read_under_ascii_and_utf8_locales
    issue_title = "positive_sum must exclude negative numbers"
    extra_issues = [{ "key" => "task_cafe", "title" => "land the fix — café" }]

    with_fake_tools(issue_title: issue_title) do |env, prompt_path|
      with_llm_worker_fixture(issue_title: issue_title, extra_issues: extra_issues) do |llm_worker|
        %w[C C.UTF-8].each do |locale|
          stdout, stderr, status = Open3.capture3(
            env.merge("LC_ALL" => locale, "LANG" => locale),
            llm_worker, "codex", "shakacode/agent-coord-sim-alpha", "7", "batch-42"
          )
          assert_equal 0, status.exitstatus, "#{locale}: #{stderr}"

          prompt = File.read(prompt_path)
          assert_includes prompt, "Issue key: task_one", locale
          assert_includes stdout, "LLM_WORKER_EXIT host=codex issue=7 issue_key=task_one", locale
          cleanup_workdir(stdout)
        end
      end
    end
  end

  def test_non_ascii_prompt_template_is_read_under_ascii_and_utf8_locales
    issue_title = "positive_sum must exclude negative numbers"
    prompt_template = File.binread(WORKER_PROMPT).dup.force_encoding(Encoding::UTF_8)
    prompt_template = "#{prompt_template}\nReview résumé — café\n"

    with_fake_tools(issue_title: issue_title) do |env, prompt_path|
      with_llm_worker_fixture(issue_title: issue_title, prompt_template: prompt_template) do |llm_worker, template_path|
        probe = write_utf8_read_probe(File.dirname(prompt_path))
        %w[C C.UTF-8].each do |locale|
          stdout, stderr, status = Open3.capture3(
            env.merge(
              "LC_ALL" => locale,
              "LANG" => locale,
              "RUBYOPT" => "-r#{probe}",
              "UTF8_READ_PROBE_PATH" => template_path
            ),
            llm_worker, "codex", "shakacode/agent-coord-sim-alpha", "7", "batch-42"
          )
          assert_equal 0, status.exitstatus, "#{locale}: #{stderr}"

          prompt = File.binread(prompt_path).dup.force_encoding(Encoding::UTF_8)
          assert_includes prompt, "Review résumé — café", locale
          assert_includes stdout, "LLM_WORKER_EXIT host=codex issue=7 issue_key=task_one", locale
          cleanup_workdir(stdout)
        end
      end
    end
  end

  def test_invalid_utf8_manifest_still_fails_closed
    issue_title = "positive_sum must exclude negative numbers"
    invalid_manifest = "{\"issues\":[{\"key\":\"task_one\",\"title\":\"bad \xFF\"}]}".b

    with_fake_tools(issue_title: issue_title) do |env, prompt_path|
      with_llm_worker_fixture(issue_title: issue_title, manifest_bytes: invalid_manifest) do |llm_worker|
        _stdout, stderr, status = Open3.capture3(
          env.merge("LC_ALL" => "C", "LANG" => "C"),
          llm_worker, "codex", "shakacode/agent-coord-sim-alpha", "7", "batch-42"
        )
        assert_equal 1, status.exitstatus
        refute_empty stderr
        refute_path_exists prompt_path
      end
    end
  end

  def test_valid_selected_record_does_not_hide_invalid_utf8_in_an_unused_title
    issue_title = "positive_sum must exclude negative numbers"
    invalid_manifest = <<~JSON.b
      {"issues":[{"key":"task_one","title":"#{issue_title}"},{"key":"unused","title":"bad \xFF"}]}
    JSON

    with_fake_tools(issue_title: issue_title) do |env, prompt_path|
      with_llm_worker_fixture(issue_title: issue_title, manifest_bytes: invalid_manifest) do |llm_worker|
        _stdout, stderr, status = Open3.capture3(
          env.merge("LC_ALL" => "C", "LANG" => "C"),
          llm_worker, "codex", "shakacode/agent-coord-sim-alpha", "7", "batch-42"
        )
        assert_equal 1, status.exitstatus
        assert_includes stderr, "simulation issue manifest is not valid UTF-8"
        refute_path_exists prompt_path
      end
    end
  end

  def test_invalid_utf8_prompt_template_still_fails_closed_downstream
    issue_title = "positive_sum must exclude negative numbers"
    invalid_prompt = "{{REPO}}\ninvalid \xFF\n".b

    with_fake_tools(issue_title: issue_title, validate_prompt_utf8: true) do |env, prompt_path|
      with_llm_worker_fixture(issue_title: issue_title, prompt_template: invalid_prompt) do |llm_worker|
        stdout, stderr, status = Open3.capture3(
          env.merge("LC_ALL" => "C", "LANG" => "C"),
          llm_worker, "codex", "shakacode/agent-coord-sim-alpha", "7", "batch-42"
        )
        refute status.success?, "#{stdout}\n#{stderr}"
        refute_empty stderr
        refute_path_exists prompt_path
        assert_includes stdout, "LLM_WORKER_EXIT host=codex issue=7 issue_key=task_one"
        assert_includes stdout, "exit=#{status.exitstatus}"
        cleanup_workdir(stdout)
      end
    end
  end

  private

  def with_fake_tools(codex_exit: 0, issue_title: "positive_sum must exclude negative numbers",
                      validate_prompt_utf8: false)
    Dir.mktmpdir do |dir|
      prompt_path = File.join(dir, "prompt.md")
      write_fake_gh(File.join(dir, "gh"))
      write_fake_codex(File.join(dir, "codex"))
      env = {
        "PATH" => "#{dir}:#{ENV.fetch('PATH')}",
        "GH_BIN" => File.join(dir, "gh"),
        "CODEX_BIN" => File.join(dir, "codex"),
        "PROMPT_OUT" => prompt_path,
        "CODEX_EXIT" => codex_exit.to_s,
        "GH_ISSUE_TITLE" => issue_title,
        "VALIDATE_PROMPT_UTF8" => validate_prompt_utf8 ? "1" : "0"
      }
      yield env, prompt_path
    end
  end

  def with_llm_worker_fixture(issue_title:, extra_issues: [], prompt_template: File.binread(WORKER_PROMPT),
                              manifest_bytes: nil)
    Dir.mktmpdir do |root|
      sim_root = File.join(root, "sim")
      llm_worker = File.join(sim_root, "bin", "llm-worker")
      FileUtils.mkdir_p(File.dirname(llm_worker))
      FileUtils.mkdir_p(File.join(sim_root, "prompts"))
      FileUtils.cp(LLM_WORKER, llm_worker)
      File.binwrite(
        File.join(sim_root, "issues.json"),
        manifest_bytes || JSON.generate(
          "issues" => [{ "key" => "task_one", "title" => issue_title }, *extra_issues]
        )
      )
      template_path = File.join(sim_root, "prompts", "worker-prompt.md")
      File.binwrite(template_path, prompt_template)
      FileUtils.chmod(0o755, llm_worker)
      yield llm_worker, template_path
    end
  end

  def write_utf8_read_probe(dir)
    probe = File.join(dir, "utf8-read-probe.rb")
    File.write(probe, <<~'RUBY')
      module Utf8ReadProbe
        def read(path, *args, **kwargs)
          content = super(path, *args, **kwargs)
          target = ENV["UTF8_READ_PROBE_PATH"]
          if target && File.expand_path(path) == File.expand_path(target) && content.encoding != Encoding::UTF_8
            raise Encoding::CompatibilityError, "expected UTF-8 file read, got #{content.encoding}"
          end
          content
        end
      end

      File.singleton_class.prepend(Utf8ReadProbe)
    RUBY
    probe
  end

  def write_fake_gh(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby

      if ARGV[0, 2] == ["issue", "view"]
        puts ENV.fetch("GH_ISSUE_TITLE")
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

      prompt = ARGV.fetch(-1)
      if ENV.fetch("VALIDATE_PROMPT_UTF8", "0") == "1"
        prompt = prompt.b.force_encoding(Encoding::UTF_8)
        unless prompt.valid_encoding?
          warn "prompt is not valid UTF-8"
          exit 23
        end
      end
      File.write(ENV.fetch("PROMPT_OUT"), prompt)
      exit ENV.fetch("CODEX_EXIT", "0").to_i
    RUBY
    FileUtils.chmod(0o755, path)
  end

  def cleanup_workdir(stdout)
    workdir = stdout[/workdir=(\S+)/, 1]
    FileUtils.remove_entry(workdir) if workdir && Dir.exist?(workdir)
  end
end
