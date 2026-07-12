# frozen_string_literal: true

require "digest"
require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("../worker/bin/provision-token", __dir__)

class ProvisionTokenTest < Minitest::Test
  TOKEN = "0123456789abcdef0123456789abcdef0123456789abcdef"

  def setup
    @tmpdir = Dir.mktmpdir
    @bindir = File.join(@tmpdir, "bin")
    @npx_args_file = File.join(@tmpdir, "npx-args")
    FileUtils.mkdir_p(@bindir)
    write_executable("openssl", <<~BASH)
      #!/usr/bin/env bash
      if [ "$1" = "rand" ] && [ "$2" = "-hex" ] && [ "$3" = "24" ]; then
        printf '%s\\n' "#{TOKEN}"
        exit 0
      fi
      if [ "$1" = "dgst" ] && [ "$2" = "-sha256" ] && [ "$3" = "-r" ]; then
        input=$(cat)
        [ "$input" = "#{TOKEN}" ] || exit 65
        printf '%s *stdin\\n' "#{Digest::SHA256.hexdigest(TOKEN)}"
        exit 0
      fi
      exit 64
    BASH
    write_executable("ruby", <<~BASH)
      #!/usr/bin/env bash
      echo "ruby should not be used" >&2
      exit 127
    BASH
    write_executable("npx", <<~BASH)
      #!/usr/bin/env bash
      printf '%s\\n' "$@" > "$NPX_ARGS_FILE"
      [ -z "${NPX_STDERR:-}" ] || printf '%s\\n' "$NPX_STDERR" >&2
      exit "${NPX_EXIT:-0}"
    BASH
    write_executable("shasum", <<~BASH)
      #!/usr/bin/env bash
      echo "shasum should not be used" >&2
      exit 127
    BASH
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_all_state_explicitly_provisions_hash_and_prints_token_in_local_mode
    stdout, stderr, status = run_script("m5", "--local", "--all-state")

    assert status.success?, stderr
    expected_hash = Digest::SHA256.hexdigest(TOKEN)
    expected_sql = "INSERT INTO machines (machine, token_hash, read_prefixes, write_prefixes, created_at) VALUES " \
                   "('m5', '#{expected_hash}', '[\"\"]', '[\"\"]', strftime('%Y-%m-%dT%H:%M:%SZ','now'))"
    assert_equal [
      "wrangler",
      "d1",
      "execute",
      "agent-coord",
      "--local",
      "--command",
      expected_sql
    ], npx_args
    refute_includes npx_args, "--yes"
    assert_includes stdout, "machine:  m5"
    assert_includes stdout, "reads:    [\"\"]"
    assert_includes stdout, "writes:   [\"\"]"
    assert_includes stdout, "token:    #{TOKEN}"
    assert_includes stdout, "export AGENT_COORD_API_TOKEN=#{TOKEN}"
    refute_includes stdout, expected_hash
  end

  def test_requires_explicit_scopes
    _, stderr, status = run_script("m5", "--local")

    refute status.success?
    assert_includes stderr, "provide at least one --read-prefix or --write-prefix, or pass --all-state"
    refute_path_exists @npx_args_file
  end

  def test_provisions_scoped_prefixes
    stdout, stderr, status = run_script(
      "m5",
      "--local",
      "--read-prefix",
      "claims/shakacode/react_on_rails",
      "--write-prefix",
      "claims/shakacode/react_on_rails",
      "--write-prefix",
      "heartbeats/m5-codex.json"
    )

    assert status.success?, stderr
    expected_hash = Digest::SHA256.hexdigest(TOKEN)
    expected_sql = "INSERT INTO machines (machine, token_hash, read_prefixes, write_prefixes, created_at) VALUES " \
                   "('m5', '#{expected_hash}', '[\"claims/shakacode/react_on_rails\"]', " \
                   "'[\"claims/shakacode/react_on_rails\",\"heartbeats/m5-codex.json\"]', " \
                   "strftime('%Y-%m-%dT%H:%M:%SZ','now'))"
    assert_equal [
      "wrangler",
      "d1",
      "execute",
      "agent-coord",
      "--local",
      "--command",
      expected_sql
    ], npx_args
    assert_includes stdout, "reads:    [\"claims/shakacode/react_on_rails\"]"
    assert_includes stdout, "writes:   [\"claims/shakacode/react_on_rails\",\"heartbeats/m5-codex.json\"]"
    refute_includes stdout, expected_hash
  end

  def test_omitted_write_scope_has_no_access
    stdout, stderr, status = run_script(
      "m5",
      "--local",
      "--read-prefix",
      "claims/shakacode/react_on_rails"
    )

    assert status.success?, stderr
    assert_includes stdout, "reads:    [\"claims/shakacode/react_on_rails\"]"
    assert_includes stdout, "writes:   []"
    sql = npx_args.fetch(npx_args.index("--command") + 1)
    assert_includes sql, "'[\"claims/shakacode/react_on_rails\"]', '[]'"
  end

  def test_provisions_write_only_scope_for_event_appenders
    stdout, stderr, status = run_script(
      "m5",
      "--local",
      "--write-prefix",
      "events/batch-1"
    )

    assert status.success?, stderr
    assert_includes stdout, "reads:    []"
    assert_includes stdout, "writes:   [\"events/batch-1\"]"
    sql = npx_args.fetch(npx_args.index("--command") + 1)
    assert_includes sql, "'[]', '[\"events/batch-1\"]'"
  end

  def test_remote_mode_uses_remote_flag
    _, stderr, status = run_script("m1", "--all-state")

    assert status.success?, stderr
    assert_includes npx_args, "--remote"
    assert_includes npx_args, "--yes"
    refute_includes npx_args, "--local"
  end

  def test_rotate_upserts_token_and_scopes_in_named_database
    _, stderr, status = run_script(
      "m5",
      "--database",
      "agent-coord-rotated-20260710",
      "--rotate",
      "--all-state"
    )

    assert status.success?, stderr
    assert_equal "agent-coord-rotated-20260710", npx_args.fetch(npx_args.index("execute") + 1)
    sql = npx_args.fetch(npx_args.index("--command") + 1)
    assert_includes sql, "ON CONFLICT(machine) DO UPDATE SET"
    assert_includes sql, "token_hash=excluded.token_hash"
    assert_includes sql, "read_prefixes=excluded.read_prefixes"
    assert_includes sql, "write_prefixes=excluded.write_prefixes"
    assert_includes sql, "revoked_at=NULL"
  end

  def test_rejects_unsafe_database_name_before_generating_token
    _, stderr, status = run_script("m5", "--database", "agent-coord;DROP", "--all-state")

    refute status.success?
    assert_includes stderr, "database name may contain"
    refute_path_exists @npx_args_file
  end

  def test_rejects_leading_dash_database_name_before_generating_token
    _, stderr, status = run_script("m5", "--database", "--verbose", "--all-state")

    refute status.success?
    assert_includes stderr, "database name cannot start with a hyphen"
    refute_path_exists @npx_args_file
  end

  def test_rejects_unsafe_machine_names_before_generating_token
    _, stderr, status = run_script("m5';DROP")

    refute status.success?
    assert_includes stderr, "machine name may contain"
    refute_path_exists @npx_args_file
  end

  def test_rejects_unknown_scope
    _, stderr, status = run_script("m5", "--bogus")

    refute status.success?
    assert_includes stderr, "usage:"
    refute_path_exists @npx_args_file
  end

  def test_rejects_empty_scope
    _, stderr, status = run_script("m5", "")

    refute status.success?
    assert_includes stderr, "usage:"
    refute_path_exists @npx_args_file
  end

  def test_rejects_empty_prefixes_as_an_all_state_bypass
    _, stderr, status = run_script(
      "m5",
      "--read-prefix",
      "",
      "--write-prefix",
      ""
    )

    refute status.success?
    assert_includes stderr, "prefix cannot be empty; pass --all-state for all-state access"
    refute_path_exists @npx_args_file
  end

  def test_rejects_all_state_combined_with_scoped_prefixes
    _, stderr, status = run_script(
      "m5",
      "--all-state",
      "--read-prefix",
      "claims/shakacode/react_on_rails",
      "--write-prefix",
      "claims/shakacode/react_on_rails"
    )

    refute status.success?
    assert_includes stderr, "--all-state cannot be combined with --read-prefix or --write-prefix"
    refute_path_exists @npx_args_file
  end

  def test_rejects_invalid_path_scope_before_generating_token
    _, stderr, status = run_script("m5", "--read-prefix", "claims/../secret")

    refute status.success?
    assert_includes stderr, "invalid read prefix"
    refute_path_exists @npx_args_file
  end

  def test_rejects_lone_scope_flag_as_machine_name
    ["--local", "--remote", "--all-state"].each do |flag|
      _, stderr, status = run_script(flag)

      refute status.success?, "expected #{flag} to be rejected"
      assert_includes stderr, "usage:"
      refute_path_exists @npx_args_file
    end
  end

  def test_wrangler_auth_failure_reports_generic_failure_without_duplicate_hint_or_token
    stdout, stderr, status = run_script(
      { "NPX_EXIT" => "19", "NPX_STDERR" => "wrangler auth expired" },
      "m5",
      "--all-state"
    )

    refute status.success?
    assert_includes stderr, "wrangler auth expired"
    assert_includes stderr, "wrangler d1 execute failed"
    refute_includes stderr, "If this was a duplicate machine"
    refute_includes stdout, TOKEN
  end

  def test_wrangler_constraint_failure_reports_duplicate_hint_without_printing_token
    stdout, stderr, status = run_script(
      { "NPX_EXIT" => "19", "NPX_STDERR" => "D1_ERROR: UNIQUE constraint failed: machines.machine" },
      "m5",
      "--all-state"
    )

    refute status.success?
    assert_includes stderr, "UNIQUE constraint failed: machines.machine"
    assert_includes stderr, "wrangler d1 execute failed"
    assert_includes stderr, "If this was a duplicate machine"
    refute_includes stdout, TOKEN
  end

  private

  def write_executable(name, body)
    path = File.join(@bindir, name)
    File.write(path, body)
    FileUtils.chmod("+x", path)
  end

  def run_script(*args)
    extra_env = args.first.is_a?(Hash) ? args.shift : {}
    env = {
      "PATH" => "#{@bindir}:#{ENV.fetch('PATH')}",
      "NPX_ARGS_FILE" => @npx_args_file,
      "NPX_BIN" => File.join(@bindir, "npx"),
      "OPENSSL_BIN" => File.join(@bindir, "openssl")
    }.merge(extra_env)
    Open3.capture3(env, SCRIPT, *args)
  end

  def npx_args
    File.readlines(@npx_args_file, chomp: true)
  end
end
