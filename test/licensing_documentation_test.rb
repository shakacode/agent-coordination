# frozen_string_literal: true

require "minitest/autorun"

class LicensingDocumentationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_repository_license_is_mit
    license = read("LICENSE")

    assert_includes license, "MIT License"
    assert_includes license, "Copyright (c) 2026 ShakaCode"
    assert_includes license, "Permission is hereby granted, free of charge"
  end

  def test_readme_states_protocol_plane_license_boundary
    readme = read("README.md")

    assert_includes readme, "## License"
    assert_includes readme, "MIT License"
    assert_includes readme, "protocol plane"
    assert_includes readme, "runtime state"
    assert_includes readme, "product plane"
    assert_includes readme, "agent-coordination-dashboard"
  end

  def test_adr_records_open_core_boundary
    adr = read("docs/adr/0002-mit-protocol-plane-open-core-boundary.md")

    assert_includes adr, "Status: accepted"
    assert_includes adr, "Protocol plane"
    assert_includes adr, "MIT License"
    assert_includes adr, "Dashboard"
    assert_includes adr, "agent-coordination-dashboard"
    assert_includes adr, "runtime state"
    assert_includes adr, "product plane"
  end

  private

  def read(path)
    File.read(File.join(ROOT, path))
  end
end
