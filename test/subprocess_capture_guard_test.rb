# frozen_string_literal: true

require "minitest/autorun"
require "ripper"
require "tmpdir"

class Capture3SourceScanner
  Site = Struct.new(:path, :definition_identity, :line, keyword_init: true)

  def scan(path, source)
    syntax_tree = Ripper.sexp(source)
    raise SyntaxError, "could not parse #{path}" unless syntax_tree

    @path = path
    @sites = []
    walk(syntax_tree, nil, nil)
    @sites
  end

  private

  def walk(node, definition_identity, lexical_owner)
    return unless node.is_a?(Array)

    nested_owner = lexical_owner_name(node)
    if nested_owner
      lexical_owner = [lexical_owner, nested_owner].compact.join("::")
      definition_identity = nil
    end
    definition_identity = definition_identity_for(node, lexical_owner) || definition_identity
    @sites << capture_site(node, definition_identity) if capture3_call?(node)
    children = node.first.is_a?(Symbol) ? node.drop(1) : node
    children.each { |child| walk(child, definition_identity, lexical_owner) }
  end

  def lexical_owner_name(node)
    constant_name(node[1]) if %i[class module].include?(node.first)
  end

  def definition_identity_for(node, lexical_owner)
    case node.first
    when :def
      "#{lexical_owner || '<top-level>'}##{node.dig(1, 1)}"
    when :defs
      owner = self_receiver?(node[1]) ? lexical_owner || "<top-level>" : constant_name(node[1])
      "#{owner || '<dynamic>'}.#{node.dig(3, 1)}"
    end
  end

  def self_receiver?(node)
    node.is_a?(Array) && node.first == :var_ref && node.dig(1, 0) == :@kw && node.dig(1, 1) == "self"
  end

  def constant_name(node)
    return unless node.is_a?(Array)

    case node.first
    when :@const
      node[1]
    when :const_ref, :top_const_ref, :var_ref
      constant_name(node[1])
    when :const_path_ref
      [constant_name(node[1]), constant_name(node[2])].compact.join("::")
    end
  end

  def capture3_call?(node)
    %i[call command_call].include?(node.first) && open3_receiver?(node[1]) && node.dig(3, 1) == "capture3"
  end

  def open3_receiver?(node)
    node = node.dig(1, 0) while node.is_a?(Array) && node.first == :paren && node[1].is_a?(Array) && node[1].one?
    return false unless node.is_a?(Array) && %i[var_ref top_const_ref].include?(node.first)

    node.dig(1, 0) == :@const && node.dig(1, 1) == "Open3"
  end

  def capture_site(node, definition_identity)
    Site.new(path: @path, definition_identity: definition_identity, line: node.dig(3, 2, 0))
  end
end

class SubprocessCaptureGuardTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUBY_SHEBANG = /\A\#!.*\bruby(?:\d+(?:\.\d+)*)?(?:\s|$)/n
  REVIEWED_HELPERS = {
    "bin/agent-coord" => "AgentCoord.capture3_utf8",
    "sim/bin/graveyard" => "<top-level>#capture3_utf8",
    "sim/bin/verify-batch" => "<top-level>#capture3_utf8"
  }.freeze

  def test_only_the_reviewed_utf8_helpers_call_open3_capture3
    sites = production_capture3_sites

    assert_empty unreviewed_sites(sites), failure_message(sites)
    assert_equal REVIEWED_HELPERS.sort, sorted_site_identities(sites), failure_message(sites)
  end

  def test_guard_reports_an_inserted_raw_capture3_call
    path = "bin/new-tool"
    source = "#!/usr/bin/env ruby\n\nOpen3\n  .capture3(\n    \"ruby\", \"-v\"\n  )\n"

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 1, offenders.length
    assert_match %r{\Abin/new-tool:\d+: Open3\.capture3 in <top-level>\z}, format_site(offenders.first)
  end

  def test_guard_reports_a_parenthesized_open3_receiver
    path = "bin/new-tool"
    source = "#!/usr/bin/env ruby\n(Open3).capture3(\"ruby\", \"-v\")\n"

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 1, offenders.length
    assert_match %r{\Abin/new-tool:\d+: Open3\.capture3 in <top-level>\z}, format_site(offenders.first)
  end

  def test_guard_reports_a_top_level_call_in_a_reviewed_file_without_a_sorting_error
    path = "sim/bin/graveyard"
    source = "#{read(path)}\nOpen3.capture3(\"ruby\", \"-v\")\n"
    sites = Capture3SourceScanner.new.scan(path, source)

    assert_equal [[path, nil], [path, "<top-level>#capture3_utf8"]], sorted_site_identities(sites)
    assert_equal 1, unreviewed_sites(sites).length
  end

  def test_guard_reports_a_same_named_helper_owned_by_another_class
    path = "sim/bin/verify-batch"
    source = <<~RUBY
      class OtherRunner
        def capture3_utf8(*)
          Open3.capture3(*)
        end
      end
    RUBY

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 1, offenders.length
    assert_match(/OtherRunner#capture3_utf8/, format_site(offenders.first))
  end

  def test_non_ruby_binary_file_is_skipped_before_utf8_parsing
    invalid_utf8 = "\xFFOpen3.capture3\n".b.force_encoding(Encoding::UTF_8)

    refute ruby_source?("bin/binary-tool", invalid_utf8)
  end

  def test_versioned_ruby_shebang_does_not_hide_a_raw_call
    path = "bin/new-tool"
    source = "#!/usr/bin/env ruby3.3\nOpen3.capture3(\"ruby\", \"-v\")\n"

    assert ruby_source?(path, source.lines.first), "expected the versioned Ruby shebang to be scanned"
    assert_equal 1, unreviewed_sites(Capture3SourceScanner.new.scan(path, source)).length
  end

  def test_production_paths_include_hidden_files
    Dir.mktmpdir do |root|
      bin_dir = File.join(root, "bin")
      Dir.mkdir(bin_dir)
      hidden_script = File.join(bin_dir, ".capture-guard-test")
      File.write(hidden_script, "#!/usr/bin/env ruby\n")

      assert_includes production_paths(root), hidden_script
    end
  end

  private

  def production_capture3_sites
    production_paths.flat_map do |path|
      relative_path = path.delete_prefix("#{ROOT}/")
      first_line = File.open(path, "rb", &:gets)
      next [] unless ruby_source?(relative_path, first_line)

      source = File.read(path, encoding: "UTF-8")
      Capture3SourceScanner.new.scan(relative_path, source)
    end
  end

  def production_paths(root = ROOT)
    Dir.glob(File.join(root, "{bin,sim/bin}", "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
  end

  def ruby_source?(path, first_line)
    path.end_with?(".rb") || first_line&.b&.match?(RUBY_SHEBANG)
  end

  def unreviewed_sites(sites)
    sites.reject do |site|
      REVIEWED_HELPERS.key?(site.path) && REVIEWED_HELPERS.fetch(site.path) == site.definition_identity
    end
  end

  def sorted_site_identities(sites)
    identities = sites.map { |site| [site.path, site.definition_identity] }
    identities.sort_by { |path, definition_identity| [path, definition_identity.to_s] }
  end

  def failure_message(sites)
    details = sites.map { |site| format_site(site) }
    "Raw Open3.capture3 calls must stay in the reviewed capture3_utf8 helpers:\n#{details.join("\n")}"
  end

  def format_site(site)
    "#{site.path}:#{site.line}: Open3.capture3 in #{site.definition_identity || '<top-level>'}"
  end

  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end
end
