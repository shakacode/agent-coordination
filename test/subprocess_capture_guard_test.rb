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
  REVIEWED_HELPERS = {
    "bin/agent-coord" => "capture3_utf8",
    "sim/bin/graveyard" => "capture3_utf8",
    "sim/bin/verify-batch" => "capture3_utf8"
  }.freeze

  def test_only_the_reviewed_utf8_helpers_call_open3_capture3
    sites = production_capture3_sites

    assert_empty unreviewed_sites(sites), failure_message(sites)
    assert_equal REVIEWED_HELPERS.sort, sites.map { |site| [site.path, site.method_name] }.sort, failure_message(sites)
  end

  def test_guard_reports_an_inserted_raw_capture3_call
    path = "bin/agent-coord"
    source = "#{read(path)}\nOpen3\n  .capture3(\n    \"ruby\", \"-v\"\n  )\n"

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 1, offenders.length
    assert_match %r{\Abin/agent-coord:\d+: Open3\.capture3 in <top-level>\z}, format_site(offenders.first)
  end

  private

  def production_capture3_sites
    production_paths.flat_map do |path|
      relative_path = path.delete_prefix("#{ROOT}/")
      source = File.read(path, encoding: "UTF-8")
      next [] unless ruby_source?(relative_path, source)

      Capture3SourceScanner.new.scan(relative_path, source)
    end
  end

  def production_paths
    Dir.glob(File.join(ROOT, "{bin,sim/bin}", "**", "*")).select { |path| File.file?(path) }
  end

  def ruby_source?(path, source)
    path.end_with?(".rb") || source.lines.first&.match?(/\A\#!.*\bruby(?:\s|$)/)
  end

  def unreviewed_sites(sites)
    sites.reject { |site| REVIEWED_HELPERS[site.path] == site.method_name }
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
