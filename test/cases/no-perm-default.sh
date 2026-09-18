#!/usr/bin/env bash
# no-perm-default fixture: g03 FAIL; --dry-run must change nothing; --fix must
# insert the "*": "ask" default, leave a .doctor.bak.* backup, and stay valid.
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_home no-perm-default
CFG="$XDG_CONFIG_HOME/opencode/opencode.jsonc"

run_doctor_json --global
assert_eq "$RC" 2 "g03 broken ⇒ exit 2"
assert_status g03 FAIL

# --dry-run: no file writes, no backups.
before="$(sha256sum "$CFG" | cut -d' ' -f1)"
run_doctor --global --fix --dry-run
assert_eq "$RC" 2 "dry-run still reports the failure"
assert_eq "$(sha256sum "$CFG" | cut -d' ' -f1)" "$before" "dry-run leaves config untouched"
assert_eq "$(backup_count)" 0 "dry-run creates no backup"

# --fix (CI=true bypasses the prompt): repairs + backup appear.
CI=true run_doctor --global --fix
assert_eq "$(grep -c '"*": "ask"' "$CFG")" 1 "fix inserted catch-all rule"
assert_eq "$(backup_count)" 1 "one backup created"

# Re-run: everything healthy again.
run_doctor_json --global
assert_eq "$RC" 0 "post-fix exit 0"
assert_status g03 OK

summary