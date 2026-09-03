# frozen_string_literal: true

require "fileutils"
require "digest"
require "minitest/autorun"
require "open3"
require "tmpdir"

class DocsValidationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CHECKER = File.join(ROOT, ".agents/bin/docs")

  def test_reports_a_broken_relative_link
    with_repository do |repo|
      write(repo, "README.md", "See [missing](docs/missing.md).\n")
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "README.md:1: broken relative link: docs/missing.md"
    end
  end

  def test_reports_an_unlabelled_opening_fence
    with_repository do |repo|
      write(repo, "README.md", "Example:\n\n```\necho hello\n```\n")
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "README.md:3: unlabelled code fence"
      refute_includes stderr, "README.md:5"
    end
  end

  def test_ignores_an_unlabelled_fence_in_unchanged_markdown
    with_repository do |repo|
      write(repo, "README.md", "# Guide\n")
      write(repo, "legacy.md", "```\nlegacy\n```\n")
      track(repo, "README.md", "legacy.md")
      commit(repo, "Add existing documentation")
      write(repo, "README.md", "# Updated guide\n")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_checks_markdown_changed_by_the_current_commit_without_origin_main
    with_repository do |repo|
      write(repo, "README.md", "# Guide\n")
      track(repo, "README.md")
      commit(repo, "Add documentation")
      write(repo, "README.md", "See [missing](missing.md).\n")
      track(repo, "README.md")
      commit(repo, "Break documentation")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: missing.md"
    end
  end

  def test_checks_tracked_markdown_when_no_base_commit_is_available
    with_repository do |repo|
      write(repo, "README.md", "See [missing](missing.md).\n")
      track(repo, "README.md")
      commit(repo, "Add shallow-checkout documentation")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: missing.md"
    end
  end

  def test_does_not_assume_the_tip_parent_is_the_pr_base
    with_repository do |repo|
      write(repo, "README.md", "# Guide\n")
      track(repo, "README.md")
      commit(repo, "Add documentation")
      write(repo, "README.md", "See [missing](missing.md).\n")
      track(repo, "README.md")
      commit(repo, "Break documentation")
      write(repo, "tool.rb", "puts :ok\n")
      track(repo, "tool.rb")
      commit(repo, "Add unrelated code")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: missing.md"
    end
  end

  def test_does_not_assume_a_two_parent_tip_proves_the_pr_base
    with_repository do |repo|
      write(repo, "README.md", "# Guide\n")
      track(repo, "README.md")
      commit(repo, "Add documentation")

      system("git", "-C", repo, "switch", "--quiet", "-c", "feature", exception: true)
      write(repo, "README.md", "See [missing](missing.md).\n")
      track(repo, "README.md")
      commit(repo, "Break documentation")

      system("git", "-C", repo, "switch", "--quiet", "-c", "upstream", "HEAD~1", exception: true)
      write(repo, "tool.rb", "puts :ok\n")
      track(repo, "tool.rb")
      commit(repo, "Add unrelated code")

      system("git", "-C", repo, "switch", "--quiet", "feature", exception: true)
      system(
        "git", "-C", repo,
        "-c", "user.name=Docs Validation Test",
        "-c", "user.email=docs-validation@example.invalid",
        "merge", "--quiet", "--no-edit", "upstream",
        exception: true
      )

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: missing.md"
    end
  end

  def test_reports_an_unlabelled_fence_inside_a_blockquote
    with_repository do |repo|
      write(repo, "README.md", "> ```\n> quoted example\n> ```\n")
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "README.md:1: unlabelled code fence"
      refute_includes stderr, "README.md:3"
    end
  end

  def test_reports_an_unlabelled_fence_inside_a_list_item
    with_repository do |repo|
      write(repo, "README.md", "- ```\n  list example\n  ```\n")
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "README.md:1: unlabelled code fence"
      refute_includes stderr, "README.md:3"
    end
  end

  def test_reports_an_unlabelled_fence_in_an_ordered_list_continuation
    with_repository do |repo|
      write(repo, "README.md", "10. Example\n\n    ```\n    list example\n    ```\n")
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "README.md:3: unlabelled code fence"
      refute_includes stderr, "README.md:5"
    end
  end

  def test_reports_an_unlabelled_fence_in_a_nested_list_continuation
    with_repository do |repo|
      write(repo, "README.md", "- outer\n  - inner\n\n    ```\n    code\n    ```\n")
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "README.md:4: unlabelled code fence"
      refute_includes stderr, "README.md:6"
    end
  end

  def test_reports_an_unlabelled_list_continuation_fence_inside_a_blockquote
    with_repository do |repo|
      write(repo, "README.md", "> 10. Example\n>\n>     ```\n>     list example\n>     ```\n")
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "README.md:3: unlabelled code fence"
      refute_includes stderr, "README.md:5"
    end
  end

  def test_closes_a_labelled_list_fence_inside_a_blockquote
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "> 10. ```markdown\n>     sample\n>     ```\n\n[broken](missing.md)\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:5: broken relative link: missing.md"
      refute_includes stderr, "unlabelled code fence"
    end
  end

  def test_closes_a_labelled_blockquote_fence_inside_a_list
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "10. Example\n\n    > ```markdown\n    > sample\n    > ```\n\n[broken](missing.md)\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:7: broken relative link: missing.md"
      refute_includes stderr, "unlabelled code fence"
    end
  end

  def test_accepts_a_link_to_a_tracked_non_markdown_file
    with_repository do |repo|
      write(repo, "README.md", "See the [schema](schema/example.json).\n")
      write(repo, "schema/example.json", "{}\n")
      track(repo, "README.md", "schema/example.json")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_allows_only_the_exact_baselined_unlabelled_fence
    with_repository do |repo|
      baselined_fence = "```\nlegacy\n```\n"
      write(repo, "README.md", "#{baselined_fence}\n```\nnew\n```\n")
      write(
        repo,
        ".agents/docs-lint-baseline.json",
        <<~JSON
          {
            "version": 1,
            "unlabelled_code_fences": {
              "README.md": [
                {
                  "line": 1,
                  "sha256": "sha256:#{Digest::SHA256.hexdigest(baselined_fence)}"
                }
              ]
            }
          }
        JSON
      )
      track(repo, "README.md", ".agents/docs-lint-baseline.json")

      stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_empty stdout
      refute_includes stderr, "README.md:1"
      assert_includes stderr, "README.md:5: unlabelled code fence"
    end
  end

  def test_rejects_a_different_fence_in_place_of_baselined_debt
    with_repository do |repo|
      legacy_fence = "```\nlegacy\n```\n"
      write(repo, "README.md", "```\nreplacement\n```\n")
      write(
        repo,
        ".agents/docs-lint-baseline.json",
        <<~JSON
          {
            "version": 1,
            "unlabelled_code_fences": {
              "README.md": [
                {
                  "line": 1,
                  "sha256": "sha256:#{Digest::SHA256.hexdigest(legacy_fence)}"
                }
              ]
            }
          }
        JSON
      )
      track(repo, "README.md", ".agents/docs-lint-baseline.json")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: baselined unlabelled code fence no longer matches"
      assert_includes stderr, "README.md:1: unlabelled code fence"
    end
  end

  def test_reports_a_broken_markdown_anchor
    with_repository do |repo|
      write(repo, "README.md", "See [missing section](guide.md#missing-section).\n")
      write(repo, "guide.md", "# Present section\n")
      track(repo, "README.md", "guide.md")

      stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "README.md:1: broken anchor: guide.md#missing-section"
    end
  end

  def test_checks_anchors_in_unchanged_link_targets
    with_repository do |repo|
      write(repo, "README.md", "See [section](guide.md#present-section).\n")
      write(repo, "guide.md", "# Present section\n")
      track(repo, "README.md", "guide.md")
      commit(repo, "Add existing documentation")
      write(repo, "README.md", "See [missing](guide.md#missing-section).\n")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken anchor: guide.md#missing-section"
    end
  end

  def test_accepts_github_style_and_duplicate_heading_anchors
    with_repository do |repo|
      write(repo, "README.md", "[first](guide.md#present-section) [second](guide.md#present-section-1)\n")
      write(repo, "guide.md", "# Present section\n\n# Present section\n")
      track(repo, "README.md", "guide.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_uses_link_text_when_building_heading_anchors
    with_repository do |repo|
      write(repo, "README.md", "[section](guide.md#use-the-guide)\n")
      write(repo, "guide.md", "# Use [the guide](details.md)\n")
      write(repo, "details.md", "# Details\n")
      track(repo, "README.md", "guide.md", "details.md")

      _stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
    end
  end

  def test_ignores_link_syntax_inside_a_labelled_code_fence
    with_repository do |repo|
      write(repo, "README.md", "```markdown\n[example](missing.md)\n```\n")
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_does_not_treat_list_content_as_a_fence_closer
    with_repository do |repo|
      write(repo, "README.md", "```markdown\n- ```\n```\n")
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_treats_an_existing_untracked_target_as_broken
    with_repository do |repo|
      write(repo, "README.md", "See [draft](draft.md).\n")
      write(repo, "draft.md", "Not tracked.\n")
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: draft.md"
    end
  end

  def test_reports_a_broken_reference_link_definition
    with_repository do |repo|
      write(repo, "README.md", "Read [the guide][guide].\n\n[guide]: docs/missing.md\n")
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:3: broken relative link: docs/missing.md"
    end
  end

  def test_reports_an_invalid_baseline_without_a_backtrace
    with_repository do |repo|
      write(repo, "README.md", "# Guide\n")
      write(repo, ".agents/docs-lint-baseline.json", "not json\n")
      track(repo, "README.md", ".agents/docs-lint-baseline.json")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, ".agents/docs-lint-baseline.json: invalid JSON"
      refute_includes stderr, "JSON::ParserError"
    end
  end

  def test_repository_documentation_passes
    stdout, stderr, status = run_checker(ROOT)

    assert status.success?, stderr
    assert_empty stdout
    assert_empty stderr
  end

  private

  def with_repository
    Dir.mktmpdir("agent-docs-check") do |repo|
      system("git", "init", "--quiet", repo, exception: true)
      yield repo
    end
  end

  def write(repo, path, content)
    absolute = File.join(repo, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, content)
  end

  def track(repo, *paths)
    system("git", "-C", repo, "add", "--", *paths, exception: true)
  end

  def commit(repo, message)
    system(
      "git", "-C", repo,
      "-c", "user.name=Docs Validation Test",
      "-c", "user.email=docs-validation@example.invalid",
      "commit", "--quiet", "-m", message,
      exception: true
    )
  end

  def run_checker(repo)
    Open3.capture3(CHECKER, "--repo-root", repo)
  end
end
