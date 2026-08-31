# frozen_string_literal: true

require "minitest/autorun"
require "ripper"

class Capture3SourceScanner
  Site = Struct.new(:path, :method_name, :line, keyword_init: true)

  def scan(path, source)
    syntax_tree = Ripper.sexp(source)
    raise SyntaxError, "could not parse #{path}" unless syntax_tree

    @path = path
    @sites = []
    walk(syntax_tree, nil)
    @sites
  end

  private

  def walk(node, method_name)
    return unless node.is_a?(Array)

    method_name = definition_name(node) || method_name
    @sites << capture_site(node, method_name) if capture3_call?(node)
    children = node.first.is_a?(Symbol) ? node.drop(1) : node
    children.each { |child| walk(child, method_name) }
  end

  def definition_name(node)
    token = node[1] if node.first == :def
    token = node[3] if node.first == :defs
    token[1] if token.is_a?(Array)
  end

  def capture3_call?(node)
    %i[call command_call].include?(node.first) && open3_receiver?(node[1]) && node.dig(3, 1) == "capture3"
  end

  def open3_receiver?(node)
    return false unless node.is_a?(Array) && %i[var_ref top_const_ref].include?(node.first)

    node.dig(1, 0) == :@const && node.dig(1, 1) == "Open3"
  end

  def capture_site(node, method_name)
    Site.new(path: @path, method_name: method_name, line: node.dig(3, 2, 0))
  end
end

class SubprocessCaptureGuardTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUBY_SHEBANG = /\A\#!.*\bruby(?:\d+(?:\.\d+)*)?(?:\s|$)/n
  REVIEWED_HELPERS = {
    "bin/agent-coord" => "capture3_utf8",
    "sim/bin/graveyard" => "capture3_utf8",
    "sim/bin/verify-batch" => "capture3_utf8"
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

  def test_guard_reports_a_top_level_call_in_a_reviewed_file_without_a_sorting_error
    path = "sim/bin/graveyard"
    source = "#{read(path)}\nOpen3.capture3(\"ruby\", \"-v\")\n"
    sites = Capture3SourceScanner.new.scan(path, source)

    assert_equal [[path, nil], [path, "capture3_utf8"]], sorted_site_identities(sites)
    assert_equal 1, unreviewed_sites(sites).length
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

  def production_paths
    Dir.glob(File.join(ROOT, "{bin,sim/bin}", "**", "*")).select { |path| File.file?(path) }
  end

  def ruby_source?(path, first_line)
    path.end_with?(".rb") || first_line&.b&.match?(RUBY_SHEBANG)
  end

  def unreviewed_sites(sites)
    sites.reject do |site|
      REVIEWED_HELPERS.key?(site.path) && REVIEWED_HELPERS.fetch(site.path) == site.method_name
    end
  end

  def sorted_site_identities(sites)
    identities = sites.map { |site| [site.path, site.method_name] }
    identities.sort_by { |path, method_name| [path, method_name.to_s] }
  end

  def failure_message(sites)
    details = sites.map { |site| format_site(site) }
    "Raw Open3.capture3 calls must stay in the reviewed capture3_utf8 helpers:\n#{details.join("\n")}"
  end

  def format_site(site)
    "#{site.path}:#{site.line}: Open3.capture3 in #{site.method_name || '<top-level>'}"
  end

  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end
end
