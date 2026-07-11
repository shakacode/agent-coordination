# Changelog

All notable changes to Agent Coordination will be documented in this file.
The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
when releases begin.

## [Unreleased]

### Added

- Reviewable RubyGem packaging for the `agent-coord` CLI.
- An explicit Ruby support floor and CI coverage for it.
- A placeholder-only `curl` walkthrough for the Worker state protocol.

### Changed

- Token provisioning now requires explicit read/write scopes, with `--all-state`
  available only as an explicit opt-out for trusted single-operator deployments.

### Fixed

- Batch status JSON now includes persisted launch prompts.

No gem has been published and no release has been tagged.
