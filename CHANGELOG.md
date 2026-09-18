# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Bilingual documentation: English and Indonesian README with language switcher.
- CHANGELOG, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, LICENSE (MIT).

### Fixed

- (none yet)

## [0.1.0] - 2026-09-18

### Added

- Initial release of `opencode-doctor`.
- Health checks for global (`~/.config/opencode`) and project (`.opencode` + `AGENTS.md`) layers.
- Human-readable and `--json` machine-readable reports.
- Safe `--fix` / `--dry-run` repairs for common config problems (permission defaults, agent-browser sandbox env).
- Automatic `.doctor.bak.<timestamp>` backups before any file mutation.
- Hermetic test suite (fake opencode shim, fixture configs, no network required).
- CI workflows: ShellCheck lint + test runner; GitHub Releases on `v*` tags.

[unreleased]: https://github.com/kiraadityaa/opencode-doctor/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kiraadityaa/opencode-doctor/releases/tag/v0.1.0
