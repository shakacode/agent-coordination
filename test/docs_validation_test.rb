# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

module DocsValidationAssertions
  ROOT = File.expand_path("..", __dir__)
  CHECKER = File.join(ROOT, ".agents/bin/docs")
  VALIDATE = File.join(ROOT, ".agents/bin/validate")

  HTML_COMMENT_CONTAINER_DOCUMENTS = [
    "> <!--\n> [literal](missing.md)\n> -->\n",
    "> > <!--\n> > [literal](missing.md)\n> > -->\n",
    "- <!--\n\n  [literal](missing.md)\n  -->\n",
    "- - <!--\n\n    [literal](missing.md)\n    -->\n",
    "> - <!--\n>\n>   [literal](missing.md)\n>   -->\n",
    "> - - <!--\n>\n>     [literal](missing.md)\n>     -->\n"
  ].freeze
  HTML_COMMENT_EXIT_DOCUMENTS = [
    "> <!--\n[real](missing.md)\n-->\n",
    "> > <!--\n> [real](missing.md)\n> -->\n",
    "- <!--\n[real](missing.md)\n-->\n",
    "- - <!--\n  [real](missing.md)\n  -->\n",
    "> - <!--\n[real](missing.md)\n-->\n",
    "> - - <!--\n>   [real](missing.md)\n>   -->\n"
  ].freeze

  def assert_document_passes(content)
    with_repository do |repo|
      write(repo, "README.md", content)
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def assert_document_reports_broken_link(content, line:)
    with_repository do |repo|
      write(repo, "README.md", content)
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:#{line}: broken relative link: missing.md"
    end
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

  def write_fence_baseline(repo, path, line:, content:)
    baseline = {
      "version" => 1,
      "unlabelled_code_fences" => {
        path => [{ "line" => line, "sha256" => "sha256:#{Digest::SHA256.hexdigest(content)}" }]
      }
    }
    write(repo, ".agents/docs-lint-baseline.json", JSON.pretty_generate(baseline))
  end

  def run_checker(repo, *)
    Open3.capture3(CHECKER, "--repo-root", repo, *)
  end

  def copy_validation_scripts(repo)
    FileUtils.mkdir_p(File.join(repo, ".agents/bin"))
    FileUtils.cp(CHECKER, File.join(repo, ".agents/bin/docs"))
    FileUtils.cp(VALIDATE, File.join(repo, ".agents/bin/validate"))
  end
end

class DocsValidationTest < Minitest::Test
  include DocsValidationAssertions

  def test_checks_utf8_tracked_paths_in_the_c_locale
    with_repository do |repo|
      write(repo, "README.md", "[Guide](café.md#guide)\n")
      write(repo, "café.md", "# Guide\n")
      track(repo, "README.md", "café.md")
      commit(repo, "Add Unicode documentation")

      stdout, stderr, status = Open3.capture3(
        { "LC_ALL" => "C", "LANG" => "C", "RUBYOPT" => nil },
        CHECKER, "--repo-root", repo
      )

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_checks_utf8_changed_paths_in_the_c_locale
    with_repository do |repo|
      write(repo, "café.md", "# Guide\n")
      track(repo, "café.md")
      commit(repo, "Add Unicode documentation")
      write(repo, "café.md", "[Missing](missing.md)\n")

      _stdout, stderr, status = Open3.capture3(
        { "LC_ALL" => "C", "LANG" => "C", "RUBYOPT" => nil },
        CHECKER, "--repo-root", repo, "--base", "HEAD"
      )

      refute status.success?
      assert_equal "café.md:1: broken relative link: missing.md\n", stderr
    end
  end

  def test_reports_invalid_utf8_git_path_output_without_a_backtrace
    with_repository do |repo|
      write(repo, "fake-bin/git", "#!/bin/sh\nprintf '\\377\\000'\n")
      FileUtils.chmod("u+x", File.join(repo, "fake-bin/git"))

      _stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{repo}/fake-bin:#{ENV.fetch('PATH')}", "LC_ALL" => "C", "RUBYOPT" => nil },
        CHECKER, "--repo-root", repo
      )

      refute status.success?
      assert_equal "git ls-files: paths must be valid UTF-8\n", stderr
    end
  end

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

  def test_reports_invalid_percent_decoded_paths_as_broken_relative_links
    ["%00", "%FF"].each do |destination|
      with_repository do |repo|
        write(repo, "README.md", "[invalid](#{destination})\n")
        track(repo, "README.md")

        stdout, stderr, status = run_checker(repo)

        refute status.success?
        assert_empty stdout
        assert_equal "README.md:1: broken relative link: #{destination}\n", stderr
      end
    end
  end

  def test_accepts_balanced_parentheses_in_a_link_destination
    with_repository do |repo|
      write(repo, "README.md", "See [the file](foo(bar).md \"A (file)\").\n")
      write(repo, "foo(bar).md", "# File\n")
      track(repo, "README.md", "foo(bar).md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_checks_a_link_after_a_balanced_parenthesis_destination
    with_repository do |repo|
      write(repo, "README.md", "[file](foo(bar).md) [missing](missing.md)\n")
      write(repo, "foo(bar).md", "# File\n")
      track(repo, "README.md", "foo(bar).md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      refute_includes stderr, "foo(bar"
      assert_includes stderr, "README.md:1: broken relative link: missing.md"
    end
  end

  def test_reports_links_after_a_quoted_title_with_an_unmatched_parenthesis
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[first](missing-one.md \"left ( parenthesis\") [second](missing-two.md)\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: missing-one.md"
      assert_includes stderr, "README.md:1: broken relative link: missing-two.md"
    end
  end

  def test_accepts_an_angle_destination_and_an_escaped_quoted_title
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[file](<foo(bar).md> \"A \\\"quoted ( title\") [missing](missing.md)\n"
      )
      write(repo, "foo(bar).md", "# File\n")
      track(repo, "README.md", "foo(bar).md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      refute_includes stderr, "foo(bar).md"
      assert_includes stderr, "README.md:1: broken relative link: missing.md"
    end
  end

  def test_reports_links_with_nested_or_escaped_brackets_in_the_label
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[outer [inner]](missing-one.md) [outer \\] bracket](missing-two.md)\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: missing-one.md"
      assert_includes stderr, "README.md:1: broken relative link: missing-two.md"
    end
  end

  def test_unescapes_markdown_punctuation_in_a_link_destination
    with_repository do |repo|
      write(repo, "README.md", "See [the file](foo\\(bar\\).md).\n")
      write(repo, "foo(bar).md", "# File\n")
      track(repo, "README.md", "foo(bar).md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
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

  def test_rejects_a_backtick_in_a_backtick_fence_info_string
    assert_document_reports_broken_link("```ruby`invalid\n[broken](missing.md)\n", line: 2)
  end

  def test_allows_backticks_in_a_tilde_fence_info_string
    assert_document_passes("~~~markdown `example`\n[example](missing.md)\n~~~\n")
  end

  def test_ignores_link_syntax_inside_an_indented_code_block
    assert_document_passes("Example:\n\n    [literal](missing.md)\n")
  end

  def test_allows_indented_code_after_heading_and_thematic_break_blocks
    assert_document_passes(<<~MARKDOWN)
      # ATX
          [atx](missing-atx.md)
      Setext
      ------
          [setext](missing-setext.md)
      ----
          [break](missing-break.md)
    MARKDOWN
  end

  def test_allows_indented_code_after_an_empty_atx_heading
    assert_document_passes("##\n    [literal](missing.md)\n")
  end

  def test_allows_indented_code_after_an_html_comment_block
    assert_document_passes("<!--\ncomment\n-->\n    [literal](missing.md)\n")
  end

  def test_keeps_html_comments_active_inside_their_opening_container
    DocsValidationAssertions::HTML_COMMENT_CONTAINER_DOCUMENTS.each do |document|
      assert_document_passes(document)
    end
  end

  def test_checks_links_after_their_html_comment_container_ends
    DocsValidationAssertions::HTML_COMMENT_EXIT_DOCUMENTS.each do |document|
      assert_document_reports_broken_link(document, line: 2)
    end
  end

  def test_ignores_link_syntax_inside_a_container_indented_code_block
    assert_document_passes("> - Example\n>\n>       [literal](missing.md)\n")
  end

  def test_ignores_link_syntax_inside_a_blockquote_indented_code_block
    assert_document_passes(">     [literal](missing.md)\n")
  end

  def test_checks_a_link_in_a_two_space_list_continuation
    assert_document_reports_broken_link("- Paragraph\n  [real](missing.md)\n", line: 2)
  end

  def test_ignores_link_syntax_inside_a_six_space_list_code_block
    assert_document_passes("- Example\n\n      [literal](missing.md)\n")
  end

  def test_checks_an_indented_link_that_continues_a_paragraph
    assert_document_reports_broken_link("Paragraph\n    [real](missing.md)\n", line: 2)
  end

  def test_checks_lazy_blockquote_paragraph_continuations
    [
      "> Paragraph\n    [real](missing.md)\n",
      "> Paragraph\n     [real](missing.md)\n",
      "> > Paragraph\n>     [real](missing.md)\n",
      "> - Paragraph\n      [real](missing.md)\n"
    ].each do |document|
      assert_document_reports_broken_link(document, line: 2)
    end
  end

  def test_ignores_an_unlabelled_fence_in_unchanged_markdown
    with_repository do |repo|
      write(repo, "README.md", "# Guide\n")
      write(repo, "legacy.md", "```\nlegacy\n```\n")
      track(repo, "README.md", "legacy.md")
      commit(repo, "Add existing documentation")
      write(repo, "README.md", "# Updated guide\n")

      stdout, stderr, status = run_checker(repo, "--base", "HEAD")

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

  def test_checks_committed_markdown_without_a_base_despite_unrelated_dirty_files
    with_repository do |repo|
      write(repo, "README.md", "See [missing](missing.md).\n")
      write(repo, "helper.rb", "puts :before\n")
      track(repo, "README.md", "helper.rb")
      commit(repo, "Add documentation and code")

      %i[clean unstaged staged].each do |state|
        write(repo, "helper.rb", "puts :after\n") if state == :unstaged
        track(repo, "helper.rb") if state == :staged
        _stdout, stderr, status = run_checker(repo)

        refute status.success?, state
        assert_includes stderr, "README.md:1: broken relative link: missing.md"
      end
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

  def test_closes_a_tab_indented_labelled_fence_inside_a_list
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "-\t```markdown\n\tcode\n\t```\n\n[broken](missing.md)\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:5: broken relative link: missing.md"
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

  def test_accepts_a_link_to_a_tracked_directory
    with_repository do |repo|
      write(repo, "README.md", "See the [documentation](docs).\n")
      write(repo, "docs/nested/guide.md", "# Guide\n")
      track(repo, "README.md", "docs/nested/guide.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_accepts_a_nested_link_to_the_repository_root
    with_repository do |repo|
      write(repo, "README.md", "# Index\n")
      write(repo, "docs/guide.md", "See the [repository root](..).\n")
      track(repo, "README.md", "docs/guide.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_checks_single_slash_links_from_the_repository_root
    with_repository do |repo|
      write(repo, "guide.md", "# Guide\n")
      write(
        repo,
        "docs/nested/index.md",
        "[root](/) [file](/guide.md?view=full#guide) [directory](/docs) " \
        "[normalized](/docs/../guide.md) [missing](/missing.md) " \
        "[outside](/../outside.md)\n"
      )
      track(repo, "guide.md", "docs/nested/index.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      refute_includes stderr, "broken relative link: /\n"
      refute_includes stderr, "broken relative link: /guide.md?view=full#guide"
      refute_includes stderr, "broken relative link: /docs"
      refute_includes stderr, "broken relative link: /docs/../guide.md"
      assert_includes stderr, "docs/nested/index.md:1: broken relative link: /missing.md"
      assert_includes stderr, "docs/nested/index.md:1: broken relative link: /../outside.md"
    end
  end

  def test_ignores_protocol_relative_links
    with_repository do |repo|
      write(repo, "README.md", "See [the external guide](//example.com/missing.md).\n")
      track(repo, "README.md")

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
end

class DocsValidationAnchorAndIntegrationTest < Minitest::Test
  include DocsValidationAssertions

  def test_builds_heading_anchors_from_decoded_rendered_text
    with_repository do |repo|
      write(repo, "README.md", "[linked](guide.md#label) [entity](guide.md#alpha--beta)\n")
      write(repo, "guide.md", "# [Label](details(part).md)\n\n# Alpha &amp; Beta\n")
      write(repo, "details(part).md", "# Details\n")
      track(repo, "README.md", "guide.md", "details(part).md")

      _stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
    end
  end

  def test_does_not_validate_reference_definitions_inside_inline_comments
    assert_document_passes("Text <!--\n[example]:missing.md\n--> visible text\n")
  end

  def test_does_not_validate_unused_reference_definitions
    assert_document_passes("[unused]:missing.md\n\nOrdinary text.\n")
  end

  def test_preserves_raw_nested_crlf_fence_baseline_identity
    with_repository do |repo|
      content = "> - ```\r\n>   legacy\r\n>   ```\r\n"
      write(repo, "README.md", content)
      write_fence_baseline(repo, "README.md", line: 1, content: content)
      track(repo, "README.md", ".agents/docs-lint-baseline.json")

      _stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
    end
  end

  def test_preserves_raw_implicit_list_fence_baseline_identity
    ["\n", "\r\n"].each do |newline|
      with_repository do |repo|
        fence = "- ```#{newline}  legacy#{newline}#{newline}"
        write(repo, "README.md", "#{fence}[Visible](missing-after-container.md)#{newline}")
        write_fence_baseline(repo, "README.md", line: 1, content: fence)
        track(repo, "README.md", ".agents/docs-lint-baseline.json")

        _stdout, stderr, status = run_checker(repo)

        refute status.success?
        assert_equal "README.md:4: broken relative link: missing-after-container.md\n", stderr
      end
    end
  end

  def test_bootstraps_its_bundle_outside_the_repository_without_inherited_bundler
    with_repository do |repo|
      write(repo, "README.md", "# Fixture\n")
      track(repo, "README.md")

      stdout, stderr, status = Open3.capture3(
        { "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "RUBYOPT" => nil },
        CHECKER, "--repo-root", repo, chdir: repo
      )

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_preserves_repeated_heading_spaces_in_github_anchors
    with_repository do |repo|
      write(repo, "README.md", "[contract](guide.md#legacy--non-stack-cli-contract-and-exit-codes)\n")
      write(repo, "guide.md", "# Legacy / Non-Stack CLI Contract And Exit Codes\n")
      track(repo, "README.md", "guide.md")

      _stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
    end
  end

  def test_preserves_heading_edge_spaces_left_after_symbol_removal
    with_repository do |repo|
      write(
        repo, "README.md",
        "[leading](guide.md#-getting-started) [trailing](guide.md#overview-) " \
        "[duplicate](guide.md#-getting-started-1) [ordinary](guide.md#ordinary-heading)\n"
      )
      write(
        repo, "guide.md",
        "# 🚀 Getting Started\n\n# Overview ✨\n\n# 🚀 Getting Started\n\n#   Ordinary Heading   \n"
      )
      track(repo, "README.md", "guide.md")

      _stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
    end
  end

  def test_checks_image_destinations_inside_link_labels
    with_repository do |repo|
      write(
        repo, "README.md",
        "[![preview](missing.png)](https://example.com)\n" \
        "[![valid](present.png)](https://example.com)\n" \
        "[outer](https://example.com/![literal](ignored.png))\n" \
        "[title](https://example.com \"![literal](ignored-title.png)\")\n"
      )
      write(repo, "present.png", "image fixture")
      track(repo, "README.md", "present.png")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_equal "README.md:1: broken relative link: missing.png\n", stderr
    end
  end

  def test_checks_reference_definitions_without_postcolon_whitespace
    with_repository do |repo|
      write(
        repo, "README.md",
        "[guide]:missing.md\n[valid]:present.md\n[external]:https://example.com\n\n" \
        "Read [guide], [valid], and [external].\n"
      )
      write(repo, "present.md", "# Present\n")
      track(repo, "README.md", "present.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_equal "README.md:5: broken relative link: missing.md\n", stderr
    end
  end

  def test_ends_fenced_code_when_its_container_ends
    [
      "> ```text\n> [literal](ignored.md)\n[real](missing.md)\n",
      "- ```text\n  [literal](ignored.md)\n[real](missing.md)\n",
      "> - ```text\n>   [literal](ignored.md)\n> [real](missing.md)\n",
      "- - ```text\n    [literal](ignored.md)\n  [real](missing.md)\n"
    ].each do |document|
      assert_document_reports_broken_link(document, line: 3)
    end
  end

  def test_preserves_blank_lines_inside_list_fences
    assert_document_passes("- ```text\n\n  [literal](missing.md)\n  ```\n")
  end

  def test_ignores_inline_html_comments_but_checks_surrounding_links
    with_repository do |repo|
      write(
        repo, "README.md",
        "[before](missing-before.md) <!-- [example](ignored.md) --> [after](missing-after.md)\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: missing-before.md"
      assert_includes stderr, "README.md:1: broken relative link: missing-after.md"
      refute_includes stderr, "ignored.md"
    end
  end

  def test_ignores_multiline_inline_html_comments_and_preserves_visible_line_numbers
    with_repository do |repo|
      write(
        repo, "README.md",
        "> Text <!--\n> [example](ignored.md)\n> --> [real](missing.md)\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:3: broken relative link: missing.md"
      refute_includes stderr, "ignored.md"
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

  def test_does_not_treat_a_data_id_as_an_html_anchor
    with_repository do |repo|
      write(repo, "README.md", "<a data-id=\"fake\">label</a>\n\nSee [fake](#fake).\n")
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:3: broken anchor: #fake"
    end
  end

  def test_ignores_anchor_markup_inside_another_elements_attribute
    with_repository do |repo|
      write(repo, "README.md", <<~MARKDOWN)
        <div data="<a id=fake>"></div>

        See [fake](#fake).
      MARKDOWN
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_equal "README.md:3: broken anchor: #fake\n", stderr
    end
  end

  def test_accepts_an_anchor_revealed_by_rendered_script_tag_filtering
    assert_document_passes(<<~MARKDOWN)
      <script>
      const example = '<a id=fake>';
      </script>

      [Fake](#fake)
    MARKDOWN
  end

  def test_accepts_quoted_and_unquoted_html_anchor_values
    ["", "\"", "'"].each do |quote|
      with_repository do |repo|
        write(repo, "README.md", <<~MARKDOWN)
          <a id=#{quote}foo#{quote}></a>
          <a name=#{quote}bar#{quote}></a>
          <a id=#{quote}a&amp;b#{quote}></a>
          <a id="self-closing"/>

          [Foo](#foo) [Bar](#bar) [Entity](#a&b) [Self closing](#self-closing)
        MARKDOWN
        track(repo, "README.md")

        stdout, stderr, status = run_checker(repo)

        assert status.success?, stderr
        assert_empty stdout
        assert_empty stderr
      end
    end
  end

  def test_does_not_accept_invalid_or_non_anchor_html_attribute_values
    with_repository do |repo|
      write(repo, "README.md", <<~MARKDOWN)
        <a data-id=fake></a>
        <a id=invalid=value></a>
        <!-- <a id=commented></a> -->
        <a id=slash/>

        [Fake](#fake) [Invalid](#invalid) [Commented](#commented) [Slash](#slash)
      MARKDOWN
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_equal %w[fake invalid commented slash].map { |anchor|
        "README.md:6: broken anchor: ##{anchor}\n"
      }.join, stderr
    end
  end

  def test_ignores_anchor_attribute_text_inside_other_quoted_values
    ["\"", "'"].product(%w[label 0label @label]).each do |quote, attribute_name|
      with_repository do |repo|
        write(repo, "README.md", <<~MARKDOWN)
          <div>
          <a id=before #{attribute_name}=#{quote}anchor id=fake-id name=fake-name > text#{quote} name=after></a>
          </div>

          [Before](#before) [After](#after) [Fake ID](#fake-id) [Fake name](#fake-name)
        MARKDOWN
        track(repo, "README.md")

        _stdout, stderr, status = run_checker(repo)

        refute status.success?
        assert_equal %w[fake-id fake-name].map { |anchor|
          "README.md:5: broken anchor: ##{anchor}\n"
        }.join, stderr
      end
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

  def test_accepts_container_nested_heading_anchors
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[quoted](guide.md#quoted-notes) [listed](guide.md#listed-notes)\n"
      )
      write(repo, "guide.md", "> # Quoted `Notes`\n\n10. Item\n\n    ## Listed Notes\n")
      track(repo, "README.md", "guide.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_accepts_setext_heading_anchors
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[top level](guide.md#top-level-heading) " \
        "[multiline](guide.md#multi-line-heading) " \
        "[quoted](guide.md#quoted-heading) " \
        "[listed](guide.md#listed-heading) " \
        "[nested](guide.md#nested-heading) " \
        "[collision](guide.md#collision-1)\n"
      )
      write(
        repo,
        "guide.md",
        "# Collision\n\nCollision\n=========\n\n" \
        "Top level heading\n=================\n\n" \
        "Multi\nline heading\n------------\n\n" \
        "> Quoted heading\n> --------------\n\n" \
        "- Listed heading\n  --------------\n\n" \
        "> - Nested\n>   heading\n>   =======\n"
      )
      track(repo, "README.md", "guide.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_does_not_record_setext_anchors_across_block_boundaries
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[blank](guide.md#blank-separated) " \
        "[definition](guide.md#definition-targetmd) " \
        "[code](guide.md#code-heading)\n"
      )
      write(
        repo,
        "guide.md",
        "Blank separated\n\n=========\n\n" \
        "[definition]: target.md\n=========\n\n    " \
        "Code heading\n    ============\n"
      )
      write(repo, "target.md", "# Target\n")
      track(repo, "README.md", "guide.md", "target.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "broken anchor: guide.md#blank-separated"
      assert_includes stderr, "broken anchor: guide.md#definition-targetmd"
      assert_includes stderr, "broken anchor: guide.md#code-heading"
    end
  end

  def test_uses_literal_inline_code_when_building_heading_anchors
    with_repository do |repo|
      write(repo, "README.md", "See [syntax](guide.md#syntax-textmissingmd).\n")
      write(repo, "guide.md", "# Syntax `[text](missing.md)`\n")
      track(repo, "README.md", "guide.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_preserves_literal_underscores_without_preserving_emphasis_delimiters_in_heading_anchors
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[literal](guide.md#config-for-my_env_var) " \
        "[duplicate](guide.md#config-for-my_env_var-1) " \
        "[emphasis](guide.md#emphasized-heading) " \
        "[strong](guide.md#strong-heading) " \
        "[escaped](guide.md#_literal_) " \
        "[code](guide.md#code-my_env_var) " \
        "[link](guide.md#read-my_env_var)\n"
      )
      write(
        repo,
        "guide.md",
        "# Config for MY_ENV_VAR\n\n# Config for MY_ENV_VAR\n\n" \
        "# _Emphasized heading_\n\n# __Strong heading__\n\n" \
        "# \\_literal\\_\n\n# Code `MY_ENV_VAR`\n\n" \
        "# Read [MY_ENV_VAR](details.md)\n"
      )
      write(repo, "details.md", "# Details\n")
      track(repo, "README.md", "guide.md", "details.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_reuses_an_unchanged_anchor_target_for_baseline_validation
    with_repository do |repo|
      legacy_document = "# Archive\n\n```\nlegacy\n```\n"
      legacy_fence = "```\nlegacy\n```\n"
      write(repo, "README.md", "# Index\n")
      write(repo, "legacy.md", legacy_document)
      write_fence_baseline(repo, "legacy.md", line: 3, content: legacy_fence)
      track(repo, "README.md", "legacy.md", ".agents/docs-lint-baseline.json")
      commit(repo, "Add existing documentation")
      write(repo, "README.md", "See the [archive](legacy.md#archive).\n")

      stdout, stderr, status = run_checker(repo, "--base", "HEAD")

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
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

  def test_ignores_markdown_link_syntax_inside_inline_code
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "# Syntax `[text](missing.md)`\n\n" \
        "Example: ``[other](also-missing.md)``.\n" \
        "Backslash: `[third](third-missing.md)\\`.\n"
      )
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_checks_a_real_link_next_to_inline_code
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "Example: `[shown](example.md)` and [real](missing.md).\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      refute_includes stderr, "example.md"
      assert_includes stderr, "README.md:1: broken relative link: missing.md"
    end
  end

  def test_reports_a_broken_inline_link_whose_destination_starts_on_the_next_line
    with_repository do |repo|
      write(repo, "README.md", "See [the guide](\n  docs/missing.md\n).\n")
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: docs/missing.md"
    end
  end

  def test_reports_multiline_inline_links_with_labels_titles_and_containers
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[the\nguide](\n  missing-top.md\n  \"A\n  title\"\n)\n\n" \
        "> [quoted](\n>   missing-quoted.md\n> )\n\n" \
        "- [listed](\n  missing-listed.md\n  )\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: missing-top.md"
      assert_includes stderr, "README.md:8: broken relative link: missing-quoted.md"
      assert_includes stderr, "README.md:12: broken relative link: missing-listed.md"
    end
  end

  def test_does_not_scan_multiline_link_syntax_across_block_or_code_boundaries
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[blank](\n\nmissing-after-blank.md\n)\n\n" \
        "`code span\n[inside](\nmissing-in-code.md\n)`\n\n" \
        "[angle](<missing\n-angle.md>)\n\n" \
        "[bare](missing\n-bare.md)\n\n" \
        "[comment](\n<!--\nmissing-in-comment.md\n-->\n\n" \
        "[real](missing-real.md)\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:22: broken relative link: missing-real.md"
      refute_includes stderr, "missing-after-blank.md"
      refute_includes stderr, "missing-in-code.md"
      refute_includes stderr, "missing-angle.md"
      refute_includes stderr, "missing-bare.md"
      refute_includes stderr, "missing-in-comment.md"
    end
  end

  def test_preserves_line_numbers_after_a_multiline_inline_code_span
    with_repository do |repo|
      write(repo, "README.md", "`literal\ncode`\n[real](missing.md)\n")
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:3: broken relative link: missing.md"
    end
  end

  def test_scans_complete_links_after_an_incomplete_inline_link_candidate
    with_repository do |repo|
      write(repo, "README.md", "[unfinished](destination \"title\n[real](missing.md)\n")
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:2: broken relative link: missing.md"
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

  def test_reports_a_broken_reference_link_at_its_use_site
    with_repository do |repo|
      write(repo, "README.md", "Read [the guide][guide].\n\n[guide]: docs/missing.md\n")
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:1: broken relative link: docs/missing.md"
    end
  end

  def test_reports_a_broken_multiline_reference_link_at_its_use_site
    with_repository do |repo|
      write(repo, "README.md", "[guide]:\n  docs/missing.md\n\nRead [the guide][guide].\n")
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:4: broken relative link: docs/missing.md"
    end
  end

  def test_accepts_multiline_reference_destinations_and_titles
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[bare]:\n  target.md \"Bare title\"\n" \
        "[angle]:\n  <target.md> 'Angle title'\n\n" \
        "Read [bare][] and [angle][].\n"
      )
      write(repo, "target.md", "# Target\n")
      track(repo, "README.md", "target.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_reports_multiline_reference_destinations_inside_containers
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "> [quoted]:\n>   missing-quoted.md\n>\n> [quoted]\n\n" \
        "- [listed]:\n  <missing-listed.md> \"Title\"\n\n  [listed]\n"
      )
      track(repo, "README.md")

      _stdout, stderr, status = run_checker(repo)

      refute status.success?
      assert_includes stderr, "README.md:4: broken relative link: missing-quoted.md"
      assert_includes stderr, "README.md:9: broken relative link: missing-listed.md"
    end
  end

  def test_does_not_carry_multiline_reference_definitions_across_block_boundaries
    with_repository do |repo|
      write(
        repo,
        "README.md",
        "[blank]:\n\n  missing-after-blank.md\n\n" \
        "> [quote]:\nmissing-after-quote.md\n\n" \
        "[code]:\n\n    missing-in-code.md\n\n" \
        "[comment]:\n<!--\nmissing-in-comment.md\n-->\n"
      )
      track(repo, "README.md")

      stdout, stderr, status = run_checker(repo)

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
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

  def test_validate_preserves_rubocop_and_runs_the_docs_gate
    with_repository do |repo|
      copy_validation_scripts(repo)
      write(repo, "README.md", "See [missing](missing.md).\n")
      track(repo, "README.md")

      fake_bin = File.join(repo, "fake-bin")
      bundle_log = File.join(repo, "bundle.log")
      write(
        repo,
        "fake-bin/bundle",
        "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$VALIDATE_BUNDLE_LOG\"\n"
      )
      FileUtils.chmod("u+x", File.join(fake_bin, "bundle"))

      _stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}",
          "VALIDATE_BUNDLE_LOG" => bundle_log,
          "BASH_ENV" => nil,
          "ENV" => nil
        },
        File.join(repo, ".agents/bin/validate"),
        "--force-exclusion"
      )

      refute status.success?
      assert File.exist?(bundle_log), stderr
      assert_equal "exec rubocop --force-exclusion\n", File.read(bundle_log)
      assert_includes stderr, "README.md:1: broken relative link: missing.md"
    end
  end
end
