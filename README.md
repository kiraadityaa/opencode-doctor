<div align="center">

<img src="assets/banner.svg" alt="opencode-doctor" width="100%">

**Health checks for your OpenCode setup — one command, diagnose and safely repair.**

Run a diagnostic pass over your global `~/.config/opencode` and project `.opencode`
layers, get a human or JSON report, and let it fix the most common problems —
with a backup made first, every time.

[![CI](https://img.shields.io/github/actions/workflow/status/kiraadityaa/opencode-doctor/ci.yml?branch=main&label=CI&logo=github)](https://github.com/kiraadityaa/opencode-doctor/actions)
[![License](https://img.shields.io/github/license/kiraadityaa/opencode-doctor?color=blue)](LICENSE)
[![Release](https://img.shields.io/github/v/release/kiraadityaa/opencode-doctor?logo=github)](https://github.com/kiraadityaa/opencode-doctor/releases)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?logo=shell)](CONTRIBUTING.md)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen?logo=github)](CONTRIBUTING.md)
[![Repo](https://img.shields.io/badge/opencode-setup--opencode-3b3b3b?logo)](https://github.com/kiraadityaa/setup-opencode)

**English** · [Bahasa Indonesia](README.id.md)

</div>

---

## What is this?

`opencode-doctor` is a single-file bash diagnostic CLI for
[OpenCode](https://opencode.ai). It checks both layers of your setup:

- **Global** — `~/.config/opencode/opencode.json(c)`: config syntax, model
  availability, permission rules, MCP servers, browser sandboxing, plugins,
  skills and instruction references.
- **Project** — `.opencode/` plus `AGENTS.md`: config parse, agent/command
  frontmatter, project skills.

It reports back in a readable terminal output or strict machine JSON, and
records an exit code you can use in scripts and CI:

| Exit code | Meaning |
|---|---|
| `0` | healthy |
| `1` | warnings — review the items listed |
| `2` | failures — fix before relying on your setup |

## Features

- **Both scopes, or one** — `--global`, `--project <dir>`, or `--both` (default).
- **Readable or machine output** — `--json` emits a strict JSON report; the
  default is a human summary with a health score.
- **Safe auto-repair** — `--fix` fixes the common problems; dry-run first with
  `--fix --dry-run`. Every real change is preceded by a
  `.doctor.bak.<timestamp>` backup and the config is re-validated before
  writing.
- **Zero install surface** — a single `doctor.sh` with dependencies you already
  have: `bash`, `python3` (stdlib only), and optionally `opencode`.
- **Offline friendly** — `--offline` skips network checks (used by the tests).

## Requirements

- Linux, macOS, or WSL
- `bash` (4+)
- `python3`
- `opencode` on `PATH` (optional for config syntax check — falls back to parsing the file)

## Install

**via release download (recommended)**

```bash
curl -fsSLO https://github.com/kiraadityaa/opencode-doctor/releases/latest/download/doctor.sh
chmod +x doctor.sh
./doctor.sh
```

**via source**

```bash
git clone https://github.com/kiraadityaa/opencode-doctor
cd opencode-doctor
bash doctor.sh
```

## Quick start

```bash
bash doctor.sh                      # check global + project layers
bash doctor.sh --global --json      # JSON report for CI/scripts
bash doctor.sh --fix --dry-run      # preview what would change
bash doctor.sh --fix                # apply safe fixes (backs up first)
cd my-app && bash doctor.sh --project . --verbose
```

## Usage

```
Usage: doctor.sh [scope] [options]

Scopes:
  --global                check the global config only
  --project <dir>         check a project dir only (walks up to find .opencode)
  --both                  check global and project layers (default)

Options:
  --json                  emit a machine-readable JSON report
  --fix                   apply safe fixes (with a .doctor.bak.<ts> backup)
  --dry-run               preview fixes without writing anything
  --offline               skip network checks
  --verbose               include passing checks in the human report
  -V, --version           print version and exit
  -h, --help              show this help and exit

Exit codes:
  0  healthy
  1  warnings
  2  failures
```

## JSON report

`--json` prints one document to stdout. Example (truncated):

```json
{
  "tool": "opencode-doctor",
  "version": "0.1.0",
  "scope": "global",
  "online": true,
  "checks": [
    {
      "id": "g01",
      "severity": "error",
      "status": "OK",
      "name": "config parses",
      "detail": "opencode debug config loaded",
      "remedy": ""
    }
  ],
  "summary": { "total": 23, "ok": 21, "warn": 1, "fail": 1 },
  "score": 87,
  "fixes_applied": [],
  "exit_code": 2
}
```

Skipped checks are not recorded, so `summary.total` varies with your config.

## Health checks

| Id | Check | Looks at | `--fix` |
|---|---|---|---|
| e01 | opencode binary | `opencode` on PATH | — |
| e02 | opencode version | latest GitHub release (skip with `--offline`) | — |
| g01 | config parses | `opencode debug config` or the file | — |
| g02 | models resolve | `model` / `small_model` vs `opencode models` | — |
| g03 | permission default | catch-all `"*"` rule in `permission.bash` | ✅ inserts `"*": "ask"` |
| g04 | footguns | `rm -rf *`, `git push --force*`, publish rules | — |
| g05 | MCP binaries | executables behind local MCP servers | — |
| g06 | MCP connectivity | `opencode mcp list` per enabled server | — |
| g07 | browser sandbox | `agent-browser` + `--no-sandbox` in VMs/containers | ✅ adds `AGENT_BROWSER_ARGS` |
| g08 | plugin paths | paths in `plugin` | — |
| g09 | skills paths | `SKILL.md` within depth 3 | — |
| g10 | instructions refs | files in `instructions` | — |
| g11 | shadowed ids | agent/command names colliding with built-ins | — |
| p01 | project config | parses or `.opencode/` present | — |
| p02/p03 | agent & command frontmatter | `description:` in `.opencode/agent*` / `command*` | — |
| p04 | project skills | `.opencode/skills/**/SKILL.md` | — |
| p05 | AGENTS.md | present in the project root | — |

## Fixes and backups

`--fix` can currently repair two problems, and the list will grow:

- **g03** — missing catch-all rule: inserts `"*": "ask"` into `permission.bash`.
- **g07** — missing browser sandbox: adds
  `"environment": { "AGENT_BROWSER_ARGS": "--no-sandbox" }` to the configured
  `agent-browser` MCP entry.

Before any change, the target config is copied to
`opencode.jsonc.doctor.bak.<timestamp>`. After the fixes are written, the file
is re-validated with `json.tool`; if it no longer parses, the backup is
restored automatically.

Use `--dry-run` (with or without `-v`) to preview exactly what `--fix` would do
without touching anything.

## Development

```bash
bash test/run.sh            # the whole suite (hermetic, no network)
shellcheck doctor.sh        # shell lint
```

`test/` contains:

- `lib.sh` — helpers: scratch HOME/XDG dirs, fixture copier, JSON assertion helpers.
- `fixtures/bin/opencode` — a fake `opencode` shim that responds to
  `debug config` / `models` / `mcp list` from fixture configs.
- `fixtures/bin/agent-browser` — stub binary for the browser check.
- `fixtures/<name>/xdg/opencode/opencode.jsonc` — configs for each scenario.
- `cases/*.sh` — five scenarios: healthy, bad-jsonc, no-perm-default,
  sandbox-gap, broken-mcp.

The tests never touch your real config and never hit the network.

## Repository

```
opencode-doctor/
├── doctor.sh          # the CLI (single file)
├── VERSION            # current version
├── test/
│   ├── run.sh         # test runner
│   ├── lib.sh         # test helpers
│   ├── fixtures/      # fake opencode + agent-browser + config fixtures
│   └── cases/         # scenario assertions
├── assets/banner.svg
└── .github/workflows/ # ci.yml + release.yml
```

## Related repositories

- [setup-opencode](https://github.com/kiraadityaa/setup-opencode) — one-command
  installer for a fully-featured OpenCode environment. Run `opencode-doctor`
  after it to verify the install.
- [opencode-blueprints](https://github.com/kiraadityaa/opencode-blueprints) —
  drop-in per-project `.opencode/` configs. Run `--project` checks against
  these blueprints.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report bugs and request features via the
issue templates; all changes are welcome.

## Security

See [SECURITY.md](SECURITY.md) for how to report vulnerabilities.

## License

[MIT](LICENSE) © kiraadityaa