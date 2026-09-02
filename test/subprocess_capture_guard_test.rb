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
    walk(syntax_tree, [], nil)
    @sites
  end

  private

  def walk(node, scope_path, definition_identity)
    return unless node.is_a?(Array)

    nested_scope = scope_identity(node)
    if nested_scope
      scope_path += [nested_scope]
      definition_identity = nil
    end
    definition_identity = definition_identity_for(node, scope_path) || definition_identity
    @sites << capture_site(node, definition_identity) if capture3_call?(node)
    children = node.first.is_a?(Symbol) ? node.drop(1) : node
    children.each { |child| walk(child, scope_path, definition_identity) }
  end

  def scope_identity(node)
    case node.first
    when :class, :module
      "#{node.first}(#{constant_name(node[1]) || '<dynamic>'})"
    when :sclass
      "singleton(#{receiver_name(node[1])})"
    end
  end

  def definition_identity_for(node, scope_path)
    definition = "def(#{node.dig(1, 1)})" if node.first == :def
    definition = "defs(#{receiver_name(node[1])}.#{node.dig(3, 1)})" if node.first == :defs
    return unless definition

    (scope_path + [definition]).join("/")
  end

  def receiver_name(node)
    self_receiver?(node) ? "self" : constant_name(node) || "<dynamic>"
  end

  def self_receiver?(node)
    node.is_a?(Array) && node.first == :var_ref && node.dig(1, 0) == :@kw && node.dig(1, 1) == "self"
  end

  def constant_name(node)
    return unless node.is_a?(Array)

    case node.first
    when :@const
      node[1]
    when :const_ref, :var_ref
      constant_name(node[1])
    when :top_const_ref
      "::#{constant_name(node[1])}"
    when :const_path_ref
      [constant_name(node[1]) || "<dynamic>", constant_name(node[2]) || "<dynamic>"].join("::")
    end
  end

  def capture3_call?(node)
    return false unless %i[call command_call].include?(node.first) && open3_receiver?(node[1])

    message = node[3]
    message.is_a?(Array) && message[1] == "capture3"
  end

  def open3_receiver?(node)
    node = unwrap_transparent_receiver(node)

    %w[Open3 ::Open3 Object::Open3 ::Object::Open3].include?(constant_name(node))
  end

  def unwrap_transparent_receiver(node)
    loop do
      return node unless node.is_a?(Array)

      case node.first
      when :paren
        statements = node[1]
      when :begin
        body = node[1]
        return node unless body.is_a?(Array) && body.first == :bodystmt

        node = body
        next
      when :bodystmt
        statements, rescue_clause, else_clause, ensure_clause = node.drop(1)
        return node if [rescue_clause, else_clause, ensure_clause].any?
      else
        return node
      end

      return node unless statements.is_a?(Array) && !statements.empty?

      node = statements.last
    end
  end

  def capture_site(node, definition_identity)
    Site.new(path: @path, definition_identity: definition_identity, line: node.dig(3, 2, 0))
  end
end

class SubprocessCaptureGuardTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUBY_SHEBANG = /\A\#!.*\bruby(?:\d+(?:\.\d+)*)?(?:\s|$)/n
  REVIEWED_HELPERS = {
    "bin/agent-coord" => "module(AgentCoord)/defs(self.capture3_utf8)",
    "sim/bin/graveyard" => "def(capture3_utf8)",
    "sim/bin/verify-batch" => "def(capture3_utf8)"
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

  def test_guard_reports_a_multi_statement_parenthesized_open3_receiver
    path = "bin/new-tool"
    source = "#!/usr/bin/env ruby\n(setup; Open3).capture3(\"ruby\", \"-v\")\n"

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 1, offenders.length
    assert_match %r{\Abin/new-tool:\d+: Open3\.capture3 in <top-level>\z}, format_site(offenders.first)
  end

  def test_guard_reports_a_begin_wrapped_open3_receiver
    path = "bin/new-tool"
    source = "#!/usr/bin/env ruby\n(begin; Open3; end).capture3(\"ruby\", \"-v\")\n"

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 1, offenders.length
    assert_match %r{\Abin/new-tool:\d+: Open3\.capture3 in <top-level>\z}, format_site(offenders.first)
  end

  def test_guard_reports_object_qualified_open3_receivers
    path = "bin/new-tool"
    source = <<~RUBY
      #!/usr/bin/env ruby
      Object::Open3.capture3("ruby", "-v")
      ::Object::Open3.capture3("ruby", "-v")
    RUBY

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 2, offenders.length
  end

  def test_guard_ignores_open3_call_shorthand_without_crashing
    path = "bin/new-tool"
    source = "#!/usr/bin/env ruby\nOpen3.()\n"

    sites = Capture3SourceScanner.new.scan(path, source)

    assert_empty sites
  end

  def test_guard_reports_a_top_level_call_in_a_reviewed_file_without_a_sorting_error
    path = "sim/bin/graveyard"
    source = "#{read(path)}\nOpen3.capture3(\"ruby\", \"-v\")\n"
    sites = Capture3SourceScanner.new.scan(path, source)

    assert_equal [[path, nil], [path, "def(capture3_utf8)"]], sorted_site_identities(sites)
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
    assert_match(%r{class\(OtherRunner\)/def\(capture3_utf8\)}, format_site(offenders.first))
  end

  def test_guard_reports_a_same_named_helper_owned_by_another_singleton_class
    path = "sim/bin/verify-batch"
    source = <<~RUBY
      class << OtherRunner
        def capture3_utf8(*)
          Open3.capture3(*)
        end
      end
    RUBY

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 1, offenders.length
    assert_match(%r{singleton\(OtherRunner\)/def\(capture3_utf8\)}, format_site(offenders.first))
  end

  def test_guard_reports_a_relative_singleton_owner_nested_under_another_module
    path = "bin/agent-coord"
    source = <<~RUBY
      module Outer
        module AgentCoord
        end

        class << AgentCoord
          def capture3_utf8(*)
            Open3.capture3(*)
          end
        end
      end
    RUBY

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 1, offenders.length
  end

  def test_guard_preserves_a_dynamic_scope_prefix
    path = "bin/agent-coord"
    source = <<~RUBY
      module factory::AgentCoord
        def self.capture3_utf8(*)
          Open3.capture3(*)
        end
      end
    RUBY

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 1, offenders.length
    assert_match(%r{module\(<dynamic>::AgentCoord\)/defs\(self\.capture3_utf8\)}, format_site(offenders.first))
  end

  def test_guard_reports_a_def_self_nested_inside_a_singleton_scope
    path = "bin/agent-coord"
    source = <<~RUBY
      module AgentCoord
        class << self
          def self.capture3_utf8(*)
            Open3.capture3(*)
          end
        end
      end
    RUBY

    offenders = unreviewed_sites(Capture3SourceScanner.new.scan(path, source))

    assert_equal 1, offenders.length
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
