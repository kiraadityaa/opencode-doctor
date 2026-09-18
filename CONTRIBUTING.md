# Contributing to opencode-doctor

Thanks for considering a contribution. This document covers the basics.

## Getting started

1. Fork and clone the repository.
2. Run the test suite locally:
   ```bash
   bash test/run.sh
   ```
3. All five test cases must pass before opening a PR.

## Development workflow

- **Shell code**: `bash -n doctor.sh && shellcheck doctor.sh` must pass.
- **Test cases**: each file under `test/cases/` is a standalone scenario.
  Add new fixtures in `test/fixtures/<name>/xdg/opencode/opencode.jsonc`.
- **Commit messages**: follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
  Use `fix(scope): ...` for bug fixes, `feat(scope): ...` for new checks, `docs(scope): ...` for docs.

## Reporting bugs

Open an issue using the **Bug report** template. Include:

- Output of `bash doctor.sh --global --json --offline 2>/dev/null`
- Operating system and bash version
- Whether opencode is installed and its version

## Proposing features

Open an issue using the **Feature request** template. Describe the problem
and your proposed solution. New health checks are welcome if they cover a
common misconfiguration.

## Code style

- `set -euo pipefail` is active; guard any command that may legitimately
  fail (e.g. `grep` with no match) with `|| true`.
- One-line `ok`/`warn`/`info`/`skip` helpers must use `if`/`then` rather
  than `[ ... ] && cmd` as the last statement of a function (bash exit-code
  trap).
- Python helpers use only the standard library (no pip dependencies).
- No emojis in user-facing output or scripts.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
