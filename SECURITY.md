# Security Policy

## Reporting a vulnerability

If you discover a security issue, please report it responsibly.

**Do not open a public issue.** Instead, email the maintainer directly at
[kiraadityaa@users.noreply.github.com](mailto:kiraadityaa@users.noreply.github.com).

Please include:

- A description of the vulnerability
- Steps to reproduce
- Any relevant logs or screenshots

You should receive an initial response within 72 hours. We will work with you
to understand and address the issue before any public disclosure.

## Scope

`opencode-doctor` is a read-only diagnostic tool. It reads configuration files
and opencode CLI output; it never transmits data over the network except for
checking the latest opencode release version (via `--offline` to skip).

The `--fix` flag modifies local configuration files and always creates a
`.doctor.bak.<timestamp>` backup before any change.
