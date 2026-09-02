# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class GithubWorkflowPolicyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_claude_review_skips_dependabot_without_enabling_dead_bot_configuration
    workflow = YAML.safe_load_file(
      File.join(ROOT, ".github/workflows/claude-code-review.yml"),
      aliases: true
    )
    job = workflow.fetch("jobs").fetch("claude-review")

    assert_equal "github.actor != 'dependabot[bot]'", job.fetch("if")

    review_step = job.fetch("steps").find do |step|
      step.fetch("id", "") == "claude-review"
    end
    refute_nil review_step
    refute review_step.fetch("with").key?("allowed_bots")
  end
end
