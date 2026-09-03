# frozen_string_literal: true

require "fileutils"
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

  def test_allows_only_the_baselined_number_of_unlabelled_fences
    with_repository do |repo|
      write(repo, "README.md", "```\nlegacy\n```\n\n```\nnew\n```\n")
      write(
        repo,
        ".agents/docs-lint-baseline.json",
        <<~JSON
          {
            "version": 1,
            "unlabelled_code_fences": {
              "README.md": 1
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

  def run_checker(repo)
    Open3.capture3(CHECKER, "--repo-root", repo)
  end
end
