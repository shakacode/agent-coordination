# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

SIM_ROOT = File.expand_path("..", __dir__)
TEMPLATE = File.join(SIM_ROOT, "template")

class SimulationTemplateTest < Minitest::Test
  POINTER = <<~MARKDOWN.chomp
    ## Agent Workflow Configuration

    Portable shared skills resolve this repo's commands and policy through:
    - **Commands** — run `.agents/bin/<name>` (`setup`, `validate`, `test`, ...); see `.agents/bin/README.md`. A missing script means that capability is n/a here.
    - **Policy / config** — `.agents/agent-workflow.yml`.
  MARKDOWN

  def setup
    @dir = Dir.mktmpdir("agent-coord-sim-template")
    @repo = File.join(@dir, "repo")
    FileUtils.mkdir_p(@repo)
    FileUtils.cp_r(File.join(TEMPLATE, "."), @repo)
    git("init", "-q")
    git("config", "user.name", "Simulation Test")
    git("config", "user.email", "simulation-test@example.invalid")
    git("add", "-A")
    git("commit", "-qm", "seed")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_agents_uses_canonical_agent_workflow_pointer
    agents = File.read(File.join(TEMPLATE, "AGENTS.md"))
    section = agents[agents.index("## Agent Workflow Configuration")..].rstrip

    assert_equal POINTER, section
  end

  def test_validate_allows_policy_only_configuration_change
    File.open(File.join(@repo, ".agents/agent-workflow.yml"), "a") do |file|
      file << "repo_prefix: ACSA\n"
    end

    _out, err, status = validate

    assert status.success?, err
  end

  def test_validate_rejects_invalid_policy_yaml
    File.write(File.join(@repo, ".agents/agent-workflow.yml"), "- not\n- a mapping\n")

    _out, err, status = validate

    refute status.success?
    assert_includes err, "Agent workflow policy must be a YAML mapping."
  end

  def test_validate_rejects_noncanonical_agents_pointer
    agents = File.join(@repo, "AGENTS.md")
    File.write(agents, File.read(agents).sub("(`setup`, `validate`, `test`, ...)", "(`ci`, `validate`, `test`)"))

    _out, err, status = validate

    refute status.success?
    assert_includes err, "Agent Workflow Configuration pointer is not canonical."
  end

  def test_ci_rejects_malicious_validator_that_exits_early
    validator = File.join(@repo, ".agents/bin/validate")
    File.write(validator, "#!/usr/bin/env bash\nexit 0\n")

    _out, err, status = validate

    refute status.success?
    assert_includes err, "Simulation validator does not match the checked contract."
  end

  def test_ci_rejects_modified_config_check
    File.open(File.join(@repo, ".agents/bin/config-check"), "a") { |file| file << "\n# bypass\n" }

    _out, err, status = validate

    refute status.success?
    assert_includes err, "config-check does not match the CI-pinned contract."
  end

  def test_config_check_reports_usage_without_base_ref
    _out, err, status = Open3.capture3(
      File.join(@repo, ".agents/bin/config-check"),
      chdir: @repo
    )

    refute status.success?
    assert_includes err, "usage: config-check <base_ref>"
    refute_includes err, "IndexError"
  end

  def test_validate_rejects_invalid_validator_syntax
    File.open(File.join(@repo, ".agents/bin/validate"), "a") { |file| file << "\nif\n" }

    _out, _err, status = validate

    refute status.success?
  end

  def test_config_check_rejects_invalid_test_script_syntax
    File.open(File.join(@repo, ".agents/bin/test"), "a") { |file| file << "\nif\n" }
    git("add", ".agents/bin/test")
    git("commit", "-qm", "invalid test script")

    _out, err, status = config_check

    refute status.success?
    assert_includes err, "Invalid shell syntax in simulation command scripts."
  end

  def test_validate_rejects_undocumented_config_contract
    readme = File.join(@repo, ".agents/bin/README.md")
    File.write(readme, File.read(readme).sub("| `config-check` |", "| `unchecked-config` |"))

    _out, err, status = validate

    refute status.success?
    assert_includes err, "Simulation command README does not document config-only validation."
  end

  def test_validate_keeps_single_task_gate
    task = File.join(@repo, "lib/task_one.rb")
    File.write(task, File.read(task).sub("numbers.sum", "numbers.reject(&:negative?).sum"))

    out, err, status = validate

    assert status.success?, err
    assert_includes out, "2 runs, 2 assertions"
  end

  def test_validate_rejects_unrelated_change
    File.open(File.join(@repo, "README.md"), "a") { |file| file << "\nunrelated\n" }

    _out, err, status = validate

    refute status.success?
    assert_includes err, "Unexpected config-only paths:"
    assert_includes err, "README.md"
  end

  def test_validate_rejects_task_mixed_with_configuration
    task = File.join(@repo, "lib/task_one.rb")
    File.write(task, File.read(task).sub("numbers.sum", "numbers.reject(&:negative?).sum"))
    File.open(File.join(@repo, "AGENTS.md"), "a") { |file| file << "\nconfiguration change\n" }

    _out, err, status = validate

    refute status.success?
    assert_includes err, "Task changes cannot be combined with config or unrelated paths:"
    assert_includes err, "AGENTS.md"
  end

  private

  def git(*args)
    system("git", "-C", @repo, *args, out: File::NULL, err: File::NULL) ||
      raise("git #{args.first} failed")
  end

  def validate
    Open3.capture3(
      { "AGENT_SIM_BASE_REF" => "HEAD" },
      File.join(@repo, ".agents/bin/ci"),
      chdir: @repo
    )
  end

  def config_check
    Open3.capture3(
      File.join(@repo, ".agents/bin/config-check"),
      "HEAD",
      chdir: @repo
    )
  end
end
