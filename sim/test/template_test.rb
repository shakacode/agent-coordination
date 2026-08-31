# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

SIM_ROOT = File.expand_path("..", __dir__)
TEMPLATE = File.join(SIM_ROOT, "template")
PROJECT_ROOT = File.expand_path("..", SIM_ROOT)

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

  def test_readme_documents_required_seam_guard_status_check
    readme = File.read(File.join(TEMPLATE, ".agents/bin/README.md"))

    assert_includes readme, "`Seam Guard / guard` as a required status check"
    assert_includes readme, "strict up-to-date branch requirement"
  end

  def test_seam_guard_workflow_revalidates_retargeted_prs_with_the_documented_check_name
    workflow = File.read(File.join(TEMPLATE, ".github/workflows/seam-guard.yml"))

    assert_includes workflow, "types: [opened, synchronize, reopened, edited]"
    assert_includes workflow, "name: Seam Guard / guard"
  end

  def test_policy_allowlists_only_the_template_workflow_actions
    policy = YAML.safe_load_file(File.join(TEMPLATE, ".agents/agent-workflow.yml"), aliases: false)

    assert_equal ["actions/checkout", "ruby/setup-ruby"], policy.fetch("trusted_actions")
  end

  def test_rubocop_explicitly_includes_template_guard_scripts
    output, status = Open3.capture2e(
      "bundle", "exec", "rubocop", "--list-target-files",
      chdir: PROJECT_ROOT
    )

    assert status.success?, output
    targets = output.lines(chomp: true)
    assert_includes targets, "sim/template/.agents/bin/config-check"
    assert_includes targets, "sim/template/.agents/bin/seam-guard"
  end

  def test_validate_allows_policy_only_configuration_change
    File.open(File.join(@repo, ".agents/agent-workflow.yml"), "a") do |file|
      file << "repo_prefix: ACSA\n"
    end

    _out, err, status = run_ci_gate

    assert status.success?, err
  end

  def test_validate_rejects_invalid_policy_yaml
    File.write(File.join(@repo, ".agents/agent-workflow.yml"), "- not\n- a mapping\n")

    _out, err, status = run_ci_gate

    refute status.success?
    assert_includes err, "Agent workflow policy must be a YAML mapping."
  end

  def test_validate_rejects_noncanonical_agents_pointer
    agents = File.join(@repo, "AGENTS.md")
    File.write(agents, File.read(agents).sub("(`setup`, `validate`, `test`, ...)", "(`ci`, `validate`, `test`)"))

    _out, err, status = run_ci_gate

    refute status.success?
    assert_includes err, "Agent Workflow Configuration pointer is not canonical."
  end

  def test_ci_rejects_malicious_validator_that_exits_early
    validator = File.join(@repo, ".agents/bin/validate")
    File.write(validator, "#!/usr/bin/env bash\nexit 0\n")

    _out, err, status = run_ci_gate

    refute status.success?
    assert_includes err, "Simulation validator does not match the checked contract."
  end

  def test_ci_rejects_modified_config_check
    File.open(File.join(@repo, ".agents/bin/config-check"), "a") { |file| file << "\n# bypass\n" }

    _out, err, status = run_ci_gate

    refute status.success?
    assert_includes err, "config-check does not match the CI-pinned contract."
  end

  def test_trusted_seam_guard_rejects_malicious_ci
    ci = File.join(@repo, ".agents/bin/ci")
    File.write(ci, "#!/usr/bin/env bash\nexit 0\n")
    git("add", ".agents/bin/ci")
    git("commit", "-qm", "malicious ci")

    _out, err, status = seam_guard("HEAD^", "HEAD")

    refute status.success?
    assert_includes err, "Unexpected guarded paths: .agents/bin/ci"
  end

  def test_trusted_seam_guard_rejects_workflow_changes
    workflow = File.join(@repo, ".github/workflows/ci.yml")
    File.write(workflow, "name: bypass\n")
    git("add", ".github/workflows/ci.yml")
    git("commit", "-qm", "malicious workflow")

    _out, err, status = seam_guard("HEAD^", "HEAD")

    refute status.success?
    assert_includes err, "Unexpected guarded paths: .github/workflows/ci.yml"
  end

  def test_trusted_seam_guard_rejects_protected_workflow_renamed_as_task
    git("mv", ".github/workflows/ci.yml", "lib/task_workflow.rb")
    git("commit", "-qm", "hide protected workflow as task")

    _out, err, status = seam_guard("HEAD^", "HEAD")

    refute status.success?
    assert_includes err, ".github/workflows/ci.yml"
  end

  def test_config_check_rejects_protected_workflow_renamed_as_task
    git("mv", ".github/workflows/ci.yml", "lib/task_workflow.rb")
    git("commit", "-qm", "hide protected workflow as task")

    _out, err, status = config_check("HEAD^")

    refute status.success?
    assert_includes err, ".github/workflows/ci.yml"
  end

  def test_seam_guard_workflow_scopes_private_repository_auth_to_fetch
    workflow = File.read(File.join(TEMPLATE, ".github/workflows/seam-guard.yml"))

    assert_includes workflow, "GITHUB_TOKEN: ${{ github.token }}"
    assert_includes workflow, 'git -c http.extraheader="AUTHORIZATION: basic ${auth_header}" fetch --no-tags origin'
    assert_includes workflow, "persist-credentials: false"
  end

  def test_trusted_seam_guard_accepts_policy_only_change
    File.open(File.join(@repo, ".agents/agent-workflow.yml"), "a") do |file|
      file << "repo_prefix: ACSA\n"
    end
    git("add", ".agents/agent-workflow.yml")
    git("commit", "-qm", "policy")

    out, err, status = seam_guard("HEAD^", "HEAD")

    assert status.success?, err
    assert_includes out, "CONFIG_ONLY"
  end

  def test_trusted_seam_guard_rejects_invalid_policy_yaml
    File.write(File.join(@repo, ".agents/agent-workflow.yml"), "- not\n- a mapping\n")
    git("add", ".agents/agent-workflow.yml")
    git("commit", "-qm", "invalid policy")

    _out, err, status = seam_guard("HEAD^", "HEAD")

    refute status.success?
    assert_includes err, "Agent workflow policy must be a YAML mapping."
  end

  def test_trusted_seam_guard_rejects_noncanonical_agents_pointer
    agents = File.join(@repo, "AGENTS.md")
    File.write(agents, File.read(agents).sub("(`setup`, `validate`, `test`, ...)", "(`ci`, `validate`, `test`)"))
    git("add", "AGENTS.md")
    git("commit", "-qm", "invalid pointer")

    _out, err, status = seam_guard("HEAD^", "HEAD")

    refute status.success?
    assert_includes err, "Agent Workflow Configuration pointer is not canonical."
  end

  def test_trusted_seam_guard_rejects_undocumented_config_contract
    readme = File.join(@repo, ".agents/bin/README.md")
    File.write(readme, File.read(readme).sub("| `config-check` |", "| `unchecked-config` |"))
    git("add", ".agents/bin/README.md")
    git("commit", "-qm", "invalid command contract")

    _out, err, status = seam_guard("HEAD^", "HEAD")

    refute status.success?
    assert_includes err, "Simulation command README does not document guarded validation."
  end

  def test_trusted_seam_guard_rejects_task_mixed_with_configuration
    task = File.join(@repo, "lib/task_one.rb")
    File.write(task, File.read(task).sub("numbers.sum", "numbers.reject(&:negative?).sum"))
    File.open(File.join(@repo, "AGENTS.md"), "a") { |file| file << "\nconfiguration change\n" }
    git("add", "lib/task_one.rb", "AGENTS.md")
    git("commit", "-qm", "mixed change")

    _out, err, status = seam_guard("HEAD^", "HEAD")

    refute status.success?
    assert_includes err, "Task changes cannot be combined with config or unrelated paths:"
  end

  def test_trusted_seam_guard_ignores_base_only_changes_for_stale_task_branch
    git("branch", "task-change")
    File.open(File.join(@repo, ".agents/agent-workflow.yml"), "a") do |file|
      file << "repo_prefix: ACSA\n"
    end
    git("add", ".agents/agent-workflow.yml")
    git("commit", "-qm", "base policy")
    base_commit = git_output("rev-parse", "HEAD")

    git("checkout", "-q", "task-change")
    task = File.join(@repo, "lib/task_one.rb")
    File.write(task, File.read(task).sub("numbers.sum", "numbers.reject(&:negative?).sum"))
    git("add", "lib/task_one.rb")
    git("commit", "-qm", "task change")

    out, err, status = seam_guard(base_commit, "HEAD")

    assert status.success?, err
    assert_includes out, "TASK_ONLY"
  end

  def test_trusted_seam_guard_validates_stale_config_branch_as_merge_tree
    agents = File.join(@repo, "AGENTS.md")
    File.write(agents, File.read(agents).sub("(`setup`, `validate`, `test`, ...)", "(`ci`, `validate`, `test`)"))
    git("add", "AGENTS.md")
    git("commit", "-qm", "old pointer contract")
    git("branch", "config-change")

    File.write(agents, File.read(agents).sub("(`ci`, `validate`, `test`)", "(`setup`, `validate`, `test`, ...)"))
    git("add", "AGENTS.md")
    git("commit", "-qm", "base pointer contract")
    base_commit = git_output("rev-parse", "HEAD")

    git("checkout", "-q", "config-change")
    File.open(File.join(@repo, ".agents/agent-workflow.yml"), "a") do |file|
      file << "repo_prefix: ACSA\n"
    end
    git("add", ".agents/agent-workflow.yml")
    git("commit", "-qm", "stale policy change")

    out, err, status = seam_guard(base_commit, "HEAD")

    assert status.success?, err
    assert_includes out, "CONFIG_ONLY"
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

  def test_config_check_handles_utf8_task_filename_under_c_locale
    task = "lib/task_café.rb"
    File.write(File.join(@repo, task), "TASK = :café\n")
    git("add", task)

    out, err, status = config_check("HEAD", { "LC_ALL" => "C", "LANG" => "C" })

    assert status.success?, err
    assert_includes out, "TASK_ONLY"
  end

  def test_seam_guard_handles_utf8_task_filename_under_c_locale
    task = "lib/task_café.rb"
    File.write(File.join(@repo, task), "TASK = :café\n")
    git("add", task)
    git("commit", "-qm", "unicode task")

    out, err, status = seam_guard(
      "HEAD^", "HEAD", { "LC_ALL" => "C", "LANG" => "C" }
    )

    assert status.success?, err
    assert_includes out, "TASK_ONLY"
  end

  def test_config_check_rejects_invalid_filename_bytes_without_a_backtrace
    env = fake_git_env("lib/task_\xFF.rb\0".b)
    env.merge!("LC_ALL" => "C", "LANG" => "C")

    _out, err, status = config_check("HEAD", env)

    refute status.success?
    assert_equal "Changed simulation paths must be valid UTF-8.\n", err
  end

  def test_seam_guard_rejects_invalid_filename_bytes_without_a_backtrace
    env = fake_git_env("lib/task_\xFF.rb\0".b)
    env.merge!("LC_ALL" => "C", "LANG" => "C")

    _out, err, status = seam_guard("HEAD", "HEAD", env)

    refute status.success?
    assert_equal "Changed simulation paths must be valid UTF-8.\n", err
  end

  def test_config_check_rejects_invalid_ci_script_syntax
    File.open(File.join(@repo, ".agents/bin/ci"), "a") { |file| file << "\nif\n" }

    _out, err, status = config_check

    refute status.success?
    assert_includes err, "Invalid shell syntax in simulation command scripts."
  end

  def test_validate_rejects_non_executable_validator
    validator = File.join(@repo, ".agents/bin/validate")
    File.chmod(0o644, validator)

    _out, err, status = run_ci_gate

    refute status.success?
    assert_includes err, "Simulation command scripts must remain executable."
  end

  def test_config_check_rejects_invalid_test_script_syntax
    File.open(File.join(@repo, ".agents/bin/test"), "a") { |file| file << "\nif\n" }
    git("add", ".agents/bin/test")
    git("commit", "-qm", "invalid test script")

    _out, err, status = config_check

    refute status.success?
    assert_includes err, "Invalid shell syntax in simulation command scripts."
  end

  def test_config_check_ignores_base_only_changes_for_stale_task_branch
    git("branch", "task-change")
    File.open(File.join(@repo, ".agents/agent-workflow.yml"), "a") do |file|
      file << "repo_prefix: ACSA\n"
    end
    git("add", ".agents/agent-workflow.yml")
    git("commit", "-qm", "base policy")
    base_commit = git_output("rev-parse", "HEAD")

    git("checkout", "-q", "task-change")
    task = File.join(@repo, "lib/task_one.rb")
    File.write(task, File.read(task).sub("numbers.sum", "numbers.reject(&:negative?).sum"))
    git("add", "lib/task_one.rb")
    git("commit", "-qm", "task change")

    out, err, status = config_check(base_commit)

    assert status.success?, err
    assert_includes out, "TASK_ONLY"
  end

  def test_validate_ignores_base_only_changes_for_stale_task_branch
    git("branch", "task-change")
    File.open(File.join(@repo, ".agents/agent-workflow.yml"), "a") do |file|
      file << "repo_prefix: ACSA\n"
    end
    git("add", ".agents/agent-workflow.yml")
    git("commit", "-qm", "base policy")
    base_commit = git_output("rev-parse", "HEAD")

    git("checkout", "-q", "task-change")
    task = File.join(@repo, "lib/task_one.rb")
    File.write(task, File.read(task).sub("numbers.sum", "numbers.reject(&:negative?).sum"))
    git("add", "lib/task_one.rb")
    git("commit", "-qm", "task change")

    out, err, status = run_ci_gate(base_commit)

    assert status.success?, err
    assert_includes out, "2 runs, 2 assertions"
  end

  def test_validate_rejects_undocumented_config_contract
    readme = File.join(@repo, ".agents/bin/README.md")
    File.write(readme, File.read(readme).sub("| `config-check` |", "| `unchecked-config` |"))

    _out, err, status = run_ci_gate

    refute status.success?
    assert_includes err, "Simulation command README does not document config-only validation."
  end

  def test_validate_keeps_single_task_gate
    task = File.join(@repo, "lib/task_one.rb")
    File.write(task, File.read(task).sub("numbers.sum", "numbers.reject(&:negative?).sum"))

    out, err, status = run_ci_gate

    assert status.success?, err
    assert_includes out, "2 runs, 2 assertions"
  end

  def test_validate_rejects_unrelated_change
    File.open(File.join(@repo, "README.md"), "a") { |file| file << "\nunrelated\n" }

    _out, err, status = run_ci_gate

    refute status.success?
    assert_includes err, "Unexpected config-only paths:"
    assert_includes err, "README.md"
  end

  def test_validate_rejects_task_mixed_with_configuration
    task = File.join(@repo, "lib/task_one.rb")
    File.write(task, File.read(task).sub("numbers.sum", "numbers.reject(&:negative?).sum"))
    File.open(File.join(@repo, "AGENTS.md"), "a") { |file| file << "\nconfiguration change\n" }

    _out, err, status = run_ci_gate

    refute status.success?
    assert_includes err, "Task changes cannot be combined with config or unrelated paths:"
    assert_includes err, "AGENTS.md"
  end

  private

  def git(*args)
    system("git", "-C", @repo, *args, out: File::NULL, err: File::NULL) ||
      raise("git #{args.first} failed")
  end

  def git_output(*args)
    output, status = Open3.capture2("git", "-C", @repo, *args)
    raise("git #{args.first} failed") unless status.success?

    output.strip
  end

  def fake_git_env(diff_output)
    fake_bin = File.join(@dir, "fake-bin")
    FileUtils.mkdir_p(fake_bin)
    fake_git = File.join(fake_bin, "git")
    File.write(fake_git, <<~RUBY)
      #!/usr/bin/env ruby
      if ARGV.include?("diff") && ARGV.include?("-z")
        STDOUT.binmode
        STDOUT.write(#{diff_output.dump}.b)
        exit 0
      end
      exec(ENV.fetch("REAL_GIT"), *ARGV)
    RUBY
    File.chmod(0o755, fake_git)

    real_git = ENV.fetch("PATH").split(File::PATH_SEPARATOR).filter_map do |directory|
      candidate = File.join(directory, "git")
      candidate if File.file?(candidate) && File.executable?(candidate)
    end.first
    raise "git executable not found" unless real_git

    {
      "PATH" => [fake_bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
      "REAL_GIT" => real_git
    }
  end

  def run_ci_gate(base_ref = "HEAD")
    Open3.capture3(
      { "AGENT_SIM_BASE_REF" => base_ref },
      File.join(@repo, ".agents/bin/ci"),
      chdir: @repo
    )
  end

  def config_check(base_ref = "HEAD", env = {})
    Open3.capture3(
      env,
      File.join(@repo, ".agents/bin/config-check"),
      base_ref,
      chdir: @repo
    )
  end

  def seam_guard(base_ref, head_ref, env = {})
    Open3.capture3(
      env,
      File.join(TEMPLATE, ".agents/bin/seam-guard"),
      @repo,
      base_ref,
      head_ref,
      chdir: @repo
    )
  end
end
