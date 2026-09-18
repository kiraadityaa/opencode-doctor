#!/usr/bin/env bash
# sandbox-gap fixture: agent-browser without AGENT_BROWSER_ARGS in a VM →
# g07 WARN; --dry-run writes nothing; --fix injects the env block + backup and
# the re-run is green.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_home sandbox-gap
export DOCTOR_ASSUME_VM=1
CFG="$XDG_CONFIG_HOME/opencode/opencode.jsonc"

run_doctor_json --global
assert_eq "$RC" 1 "sandbox gap ⇒ exit 1"
assert_status g07 WARN

before="$(sha256sum "$CFG" | cut -d' ' -f1)"
run_doctor --global --fix --dry-run
assert_eq "$(sha256sum "$CFG" | cut -d' ' -f1)" "$before" "dry-run leaves config untouched"
assert_eq "$(backup_count)" 0 "dry-run creates no backup"

CI=true run_doctor --global --fix
assert_eq "$(grep -c '"AGENT_BROWSER_ARGS":\s*"--no-sandbox"' "$CFG")" 1 "fix added AGENT_BROWSER_ARGS"
assert_eq "$(backup_count)" 1 "one backup created"

run_doctor_json --global
assert_eq "$RC" "$(printf '%s' "$OUT" | python3 -c "import json,sys;d=json.load(sys.stdin);print(0 if d['summary']['warn']==0 and d['summary']['fail']==0 else 1)")" "post-fix config healthy"
assert_status g07 OK

summary